#!/bin/bash
#
# extabit.com module
# Copyright (c) 2012 Plowshare team
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

MODULE_EXTABIT_REGEXP_URL="http://\(www\.\)\?extabit\.com/file/"

MODULE_EXTABIT_DOWNLOAD_OPTIONS=""
MODULE_EXTABIT_DOWNLOAD_RESUME=no
MODULE_EXTABIT_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

# Output an extabit.com file download URL
# $1: cookie file
# $2: extabit url
# stdout: real file download link
extabit_download() {
    eval "$(process_options extabit "$MODULE_EXTABIT_DOWNLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local URL=$2
    local BASE_URL='http://extabit.com'
    local PAGE DIV_ID WAIT_TIME JSON ERR QUERY FILE_NAME FILE_URL

    PAGE=$(curl -c "$COOKIE_FILE" -b 'language=en' "$URL") || return

    # <h1>File not found</h1>
    if match 'page_404_header' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Next free download from your ip will be available in
    if match 'free download from your ip' "$PAGE"; then
        WAIT_TIME=$(echo "$PAGE" | \
            parse_line_after 'download-link' '<b>\([[:digit:]]\+\) minute')
        echo $((WAIT_TIME * 60))
        return $ERR_LINK_TEMP_UNAVAILABLE

    # Only premium users can download this file.
    elif match 'premium users can download' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FILE_NAME=$(echo "$PAGE" | parse_attr 'div title' title)
    DIV_ID=$(echo "$PAGE" | parse '\.captchatimer' "#\([^']\+\)") || return
    WAIT_TIME=$(echo "$PAGE" | parse_tag "=\"$DIV_ID\"" div) || return

    wait $((WAIT_TIME)) || return

    # reCaptcha part
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6LcEvs0SAAAAAAykpzcaaxpegnSndWcEWYsSMs0M'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    JSON=$(curl --get -b "$COOKIE_FILE" -b 'language=en' \
        -d 'type=recaptcha' \
        -d "challenge=$CHALLENGE" \
        -d "capture=$WORD" \
        "$URL") || return

    #{"err":"Entered digits are incorrect."}
    #{"ok":true,"href":"?af"}
    if ! match_json_true 'ok' "$JSON"; then
        ERR=$(echo "$JSON" | parse_json_quiet err)
        test "$ERR" && log_error "Remote error: $ERR"

        captcha_nack $ID
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug "correct captcha"

    QUERY=$(echo "$JSON" | parse_json href) || return
    PAGE=$(curl --get -b "$COOKIE_FILE" -b 'language=en' \
        "$URL$QUERY") || return

    FILE_URL=$(echo "$PAGE" | parse_attr 'Download file' href) || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}
