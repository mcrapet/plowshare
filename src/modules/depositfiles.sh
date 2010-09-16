#!/bin/bash
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
MODULE_DEPOSITFILES_UPLOAD_OPTIONS=
MODULE_DEPOSITFILES_LIST_OPTIONS=
MODULE_DEPOSITFILES_DOWNLOAD_CONTINUE=no

# Output a depositfiles file download URL (free download)
# $1: DEPOSITFILES_URL
# stdout: real file download link
depositfiles_download() {
    set -e
    eval "$(process_options depositfiles "$MODULE_DEPOSITFILES_DOWNLOAD_OPTIONS" "$@")"
    URL=$1

    BASEURL="depositfiles.com"
    while retry_limit_not_reached || return 3; do
        START=$(curl -L "$URL")
        match "no_download_msg" "$START" &&
            { log_debug "file not found"; return 254; }
        test "$CHECK_LINK" && return 255
        match "download_started()" "$START" && {
            log_debug "direct download"
            FILE_URL=$(echo "$START" | parse "download_started()" 'action="\([^"]*\)"') ||
                { log_error "form parse error in direct download"; return 1; }
            echo "$FILE_URL"
            return 0
        }
        check_wait "$START" "hour" "3600" || continue
        check_wait "$START" "minute" "60" || continue
        check_wait "$START" "second" "1" || continue
        check_ip "$START" || continue
        WAIT_URL=$(echo "$START" | grep "files/" \
                | parse '<form' 'action="\([^"]*\)"') ||
            { log_error "download form not found"; return 1; }
        test "$CHECK_LINK" && return 255
        DATA=$(curl --data "gateway_result=1" "${BASEURL}${WAIT_URL}") ||
            { log_error "can't get wait URL contents"; return 1; }
        match "get_download_img_code.php" "$DATA" && {
           log_error "Site asked asked for a captcha to be solved. Aborting"
           return 1
        }
        check_wait "$DATA" "hour" "3600" || continue
        check_wait "$DATA" "minute" "60" || continue
        check_wait "$DATA" "second" "1" || continue
        check_ip "$DATA" || continue
        break
    done
    FILE_URL=$(echo "$DATA" | parse "download_started" 'action="\([^"]*\)"') ||
        { log_error "cannot find download action"; return 1; }
    SLEEP=$(echo "$DATA" | parse "download_waiter_remain" ">\([[:digit:]]\+\)<") ||
        { log_error "cannot get wait time"; return 1; }

    # usual wait time is 60 seconds
    wait $((SLEEP + 1)) seconds || return 2

    echo $FILE_URL
}

check_wait() {
    local HTML=$1
    local WORD=$2
    local FACTOR=$3
    LIMIT=$(echo "$HTML" | grep -A1 "try in" |
        parse "$WORD" "\(\<[[:digit:]:]\+\>\) $WORD" 2>/dev/null |
        sed "s/:.*$//") || true
    if test "$LIMIT"; then
        log_debug "limit reached: waiting $LIMIT ${WORD}s"
        wait $((LIMIT*FACTOR)) seconds || return 2
        return 1
    else
        return 0
    fi
}

check_ip() {
    echo "$1" | grep -q '<div class="ipbg">' || return 0
    local WAIT=60
    log_debug "IP already downloading, waiting $WAIT seconds"
    wait $WAIT seconds || return 2
    return 1
}

# List a depositfiles shared file folder URL
# $1: DEPOSITFILES_URL
# stdout: list of links
depositfiles_list() {
    eval "$(process_options depositfiles "$MODULE_DEPOSITFILES_LIST_OPTIONS" "$@")"
    URL=$1

    if ! match 'depositfiles\.com\/\(..\/\)\?folders\/' "$URL"; then
        log_error "This is not a directory list"
        return 1
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
