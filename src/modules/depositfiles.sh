#!/bin/bash
#
# depositfiles.com module
# Copyright (c) 2010-2011 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_DEPOSITFILES_REGEXP_URL="http://\(\w\+\.\)\?depositfiles\.com/"

MODULE_DEPOSITFILES_DOWNLOAD_OPTIONS=""
MODULE_DEPOSITFILES_DOWNLOAD_RESUME=yes
MODULE_DEPOSITFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

MODULE_DEPOSITFILES_LIST_OPTIONS=""

# Output a depositfiles file download URL (free download)
# $1: cookie file (unused here)
# $2: depositfiles.com url
# stdout: real file download link
depositfiles_download() {
    local URL="$2"
    local BASEURL="http://depositfiles.com"

    local START DLID WAITTIME DATA FID SLEEP

    while retry_limit_not_reached || return; do
        START=$(curl -L "$URL") || return

        if match "no_download_msg" "$START"; then
            log_debug "file not found"
            return $ERR_LINK_DEAD
        fi

        test "$CHECK_LINK" && return 0

        match "download_started()" "$START" && {
            log_debug "direct download"
            FILE_URL=$(echo "$START" | parse "download_started()" 'action="\([^"]*\)"') ||
                { log_error "form parse error in direct download"; return 1; }
            echo "$FILE_URL"
            return 0
        }

        DLID=$(echo "$START" | parse 'form action=' 'files%2F\([^"]*\)')
        log_debug "download ID: $DLID"
        if [ -z "$DLID" ]; then
            log_error "Can't parse download id, site updated"
            return $ERR_FATAL
        fi

        # 1. Check for error messages (first page)

        # - You have reached your download time limit.<br>Try in 10 minutes or use GOLD account.
        if match 'download time limit' "$START"; then
            WAITTIME=$(echo "$START" | parse 'Try in' "in \([[:digit:]:]*\) minutes")
            if [[ "$WAITTIME" -gt 0 ]]; then
                wait "$WAITTIME" minutes || return
            else
                # Arbitrary wait
                wait 60 seconds || return
            fi
            continue
        fi

        DATA=$(curl --data "gateway_result=1" "$BASEURL/en/files/$DLID") || return

        # 2. Check if we have been redirected to initial page
        if match '<input type="button" value="Gold downloading"' "$DATA"; then
            continue
        fi

        # 3. Check for error messages (second page)

        # - Attention! You used up your limit for file downloading!
        if match 'limit for file' "$DATA"; then
           WAITTIME=$(echo "$DATA" | parse 'class="html_download_api-limit_interval"' \
                   'l">\([^<]*\)<')
           log_debug "limit reached: waiting $WAITTIME seconds"
           wait $((WAITTIME)) seconds || return
           continue

        # - Such file does not exist or it has been removed for infringement of copyrights.
        elif match 'html_download_api-not_exists' "$DATA"; then
            log_error "file does not exist anymore"
            return $ERR_LINK_DEAD
        fi

        break
    done

    # FIXME: saw reCaptcha stuff in $DATA, must detect that

    FID=$(echo "$DATA" | parse 'var[[:space:]]fid[[:space:]]=' "[[:space:]]'\([^']*\)") ||
        { log_error "cannot find fid"; return $ERR_FATAL; }

    SLEEP=$(echo "$DATA" | parse "download_waiter_remain" ">\([[:digit:]]\+\)<") ||
        { log_error "cannot get wait time"; return $ERR_FATAL; }

    # Usual wait time is 60 seconds
    wait $((SLEEP + 1)) seconds || return

    DATA=$(curl --location "$BASEURL/get_file.php?fid=$FID") || return
    echo "$DATA" | parse_form_action
}

# List a depositfiles shared file folder URL
# $1: depositfiles.com link
# stdout: list of links
depositfiles_list() {
    local URL=$1

    if ! match 'depositfiles\.com/\(../\)\?folders/' "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    LINKS=$(curl -L "$URL" | parse_all 'target="_blank"' '\(<a href="http[^<]*<\/a>\)') || \
        { log_error "Wrong directory list link"; return 1; }

    # First pass : print debug message
    while read LINE; do
        FILE_NAME=$(echo "$LINE" | parse_attr '<a' 'title')
        log_debug "$FILE_NAME"
    done <<< "$LINKS"

    # Second pass : print links (stdout)
    while read LINE; do
        FILE_URL=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$FILE_URL"
    done <<< "$LINKS"
}
