#!/bin/bash
#
# depositfiles.com module
# Copyright (c) 2010 - 2011 Plowshare team
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
MODULE_DEPOSITFILES_LIST_OPTIONS=""
MODULE_DEPOSITFILES_DOWNLOAD_CONTINUE=no

# Output a depositfiles file download URL (free download)
# $1: DEPOSITFILES_URL
# stdout: real file download link
depositfiles_download() {
    set -e
    eval "$(process_options depositfiles "$MODULE_DEPOSITFILES_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    BASEURL="http://depositfiles.com"

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

        local FORM_HTML=$(grep_form_by_order "$START" 2)
        local form_gw_res=$(echo "$FORM_HTML" | parse_form_input_by_name 'gateway_result')
        WAIT_URL=$(echo "$FORM_HTML" | parse_form_action)

        if [ -z "$WAIT_URL" ]; then
            log_error "Can't parse download form, site updated?"
            return 1
        fi

        test "$CHECK_LINK" && return 255

        DATA=$(curl --data "gateway_result=$form_gw_res" "$BASEURL$WAIT_URL") ||
            { log_error "can't get wait URL contents"; return 1; }

        # is it still useful ?
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

    FILE_URL=$(echo "$DATA" | parse "download_container" "load('\([^']*\)") ||
        { log_error "cannot find download url"; return 1; }
    SLEEP=$(echo "$DATA" | parse "download_waiter_remain" ">\([[:digit:]]\+\)<") ||
        { log_error "cannot get wait time"; return 1; }

    # Usual wait time is 60 seconds
    wait $((SLEEP + 1)) seconds || return 2

    DATA=$(curl --location "$BASEURL$FILE_URL") ||
        { log_error "cannot get final url"; return 1; }

    echo "$DATA" | parse_form_action
}

check_wait() {
    local HTML=$1
    local WORD=$2
    local FACTOR=$3
    LIMIT=$(echo "$HTML" | grep -A1 "try in" |
        parse_quiet "$WORD" "\(\<[[:digit:]:]\+\>\) $WORD" |
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
