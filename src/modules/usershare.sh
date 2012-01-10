#!/bin/bash
#
# usershare.net module
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

MODULE_USERSHARE_REGEXP_URL="http://\(www\.\)\?usershare\.net/"

MODULE_USERSHARE_DOWNLOAD_OPTIONS=""
MODULE_USERSHARE_DOWNLOAD_RESUME=no
MODULE_USERSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

# Output an usershare file download URL (anonymous)
# $1: cookie file
# $2: usershare url
# stdout: real file download link
usershare_download() {
    eval "$(process_options usershare "$MODULE_USERSHARE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL=$(echo "$2" | replace '/user/' '/')
    local PAGE WAITTIME CAPTCHA CODE DIGIT XCOORD FILE_URL

    if [ -s "$COOKIEFILE" ]; then
        PAGE=$(curl -b "$COOKIEFILE" "$URL") || return
    else
        PAGE=$(curl -c "$COOKIEFILE" "$URL") || return
    fi

    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # FIXME: deal with time limit

    test "$CHECK_LINK" && return 0

    local FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_DOWN
    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1')
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op')
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
    FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand')
    FORM_DOWN=$(echo "$FORM_HTML" | parse_form_input_by_name 'down_direct')

    WAITTIME=$(echo "$FORM_HTML" | parse 'countdown_str' '">\([[:digit:]]\+\)<\/') || return

    # Funny captcha, this is text (4 digits)!
    # <span style='position:absolute;padding-left:25px;padding-top:6px;'>&#49;</span>
    CAPTCHA=$(echo "$FORM_HTML" | grep 'padding-' | sed -e 's/<span/\n<span/g' | grep 'padding-')
    CODE=0
    while read LINE; do
        DIGIT=$(echo "$LINE" | parse 'padding-' '>&#\([[:digit:]]\+\);<') || return
        XCOORD=$(echo "$LINE" | parse 'padding-' '-left:\([[:digit:]]\+\)p') || return

        # Depending x, guess digit rank
        if (( XCOORD < 15 )); then
            (( CODE = CODE + 1000 * (DIGIT-48) ))
        elif (( XCOORD < 30 )); then
            (( CODE = CODE + 100 * (DIGIT-48) ))
        elif (( XCOORD < 50 )); then
            (( CODE = CODE + 10 * (DIGIT-48) ))
        else
            (( CODE = CODE + (DIGIT-48) ))
        fi
    done <<< "$CAPTCHA"

    wait $((WAITTIME + 1)) || return

    PAGE=$(curl -b "$COOKIEFILE" --referer "$URL" --data \
        "op=${FORM_OP}&id=${FORM_ID}&rand=${FORM_RAND}&referer=&method_free=&method_premium=&code=${CODE}&down_direct=${FORM_DOWN}" \
        "$URL") || return

    if match 'Wrong captcha' "$PAGE"; then
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr 'class="button"' 'href')
    echo "$FILE_URL"
}
