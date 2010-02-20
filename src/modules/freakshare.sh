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
#

MODULE_FREAKSHARE_REGEXP_URL="^http://\(www\.\)\?freakshare\.net/files/"
MODULE_FREAKSHARE_DOWNLOAD_OPTIONS=""
MODULE_FREAKSHARE_UPLOAD_OPTIONS=
MODULE_FREAKSHARE_DOWNLOAD_CONTINUE=no

# Output an freakshare.net file download URL (anonymous, NOT PREMIUM)
#
# $1: a freakshare.net url
#
freakshare_download() {
    set -e
    eval "$(process_options storage_to "$MODULE_FREAKSHARE_DOWNLOAD_OPTIONS" "$@")"

    URL="$1?language=en"
    COOKIES=$(create_tempfile)

    WAIT_HTML=$(curl -c $COOKIES "$URL")

    $(match '\(This file does not exist\)' "$WAIT_HTML") &&
        { error "File not found"; return 254; }

    local WAIT_TIME=$(echo "$WAIT_HTML" | parse 'var[[:space:]]\+time' \
            'time[[:space:]]*=[[:space:]]*\([[:digit:]]\+\)\.[[:digit:]]*;') ||
        { error "can't get sleep time"; return 1; }

    if test "$CHECK_LINK"; then
        rm -f $COOKIES
        return 255
    fi

    # Skip first form (Premium Download)
    WAIT_HTML=$(echo "$WAIT_HTML" | sed -n '/<\/form>/,/<\/form>/{//d;p}')
    local form_url=$(echo "$WAIT_HTML" | parse '<form .*>' 'action="\([^"]*\)' 2>/dev/null)
    local form_submit=$(echo "$WAIT_HTML" | parse '<input\([[:space:]]*[^ ]*\)*type="submit"' 'value="\([^"]*\)' 2>/dev/null)
    local form_section=$(echo "$WAIT_HTML" | parse '<input\([[:space:]]*[^ ]*\)*name="section"' 'value="\([^"]*\)' 2>/dev/null)
    local form_did=$(echo "$WAIT_HTML" | parse '<input\([[:space:]]*[^ ]*\)*name="did"' 'value="\([^"]*\)' 2>/dev/null)

    countdown $((WAIT_TIME)) 10 seconds 1 || return 2

    # Send (post) form to access captcha screen
    WAIT_HTML2=$(curl -b $COOKIES --data "submit=${form_submit}&section=${form_section}&did=${form_did}" "$form_url")
    local form2_url=$(echo "$WAIT_HTML2" | parse '<form .*>' 'action="\([^"]*\)' 2>/dev/null)
    local form2_submit=$(echo "$WAIT_HTML2" | parse '<input\([[:space:]]*[^ ]*\)*type="submit"' 'value="\([^"]*\)' 2>/dev/null)
    local form2_section=$(echo "$WAIT_HTML2" | parse '<input\([[:space:]]*[^ ]*\)*name="section"' 'value="\([^"]*\)' 2>/dev/null)
    local form2_did=$(echo "$WAIT_HTML2" | parse '<input\([[:space:]]*[^ ]*\)*name="did"' 'value="\([^"]*\)' 2>/dev/null)

    # Clean HTML code: <b> marker is not present!
    # <h1 style="text-align:center;">filename</b></h1>
    FILENAME=$(echo "$WAIT_HTML2" | parse '<h1 style' '">\([^<]*\)<\/')

    if match '\(name="sum"\)' "$WAIT_HTML2"
    then
        CAPTCHA_URL=$(echo "$WAIT_HTML2" | parse '\/captcha\/' 'src="\([^"]*\)')

        local try=0
        while retry_limit_not_reached || return 3; do
            ((try++))
            debug "Try $try:"

            CAPTCHA=$(curl -b $COOKIES "$CAPTCHA_URL" | show_image_and_tee | ocr digit_ops) ||
                { error "error running OCR"; return 1; }

            # Expected format: "5+1="
            CAPTCHA_NUM=$(echo "$CAPTCHA" | cut -d'=' -f1)

            if ! match '\(+\)' "$CAPTCHA_NUM"; then
                debug "Captcha result is invalid"
                continue
            fi

            CAPTCHA_NUM=$((CAPTCHA_NUM))
            debug "Decoded captcha: $CAPTCHA$CAPTCHA_NUM"

            # Send (post) form
            LAST_HTML=$(curl -i -b $COOKIES --data "submit=${form2_submit}&section=${form2_section}&did=${form2_did}&sum=${CAPTCHA_NUM}" \
                    "$form2_url") || return 1

            FILE_URL=$(echo "$LAST_HTML" | head -n16 | grep_http_header_location 2>/dev/null)
            if [ -n "$FILE_URL" ]; then
              debug "Correct captcha!"
              break
            fi

            debug "Wrong captcha"
        done

    else
        debug "No captcha!"

        # Send (post) form
        LAST_HTML=$(curl -i -b $COOKIES --data "submit=${form2_submit}&section=${form2_section}&did=${form2_did}" \
                "$form2_url") || return 1
        FILE_URL=$(echo "$LAST_HTML" | head -n16 | grep_http_header_location 2>/dev/null)
    fi

    rm -f $COOKIES

    echo "$FILE_URL"
    echo "$FILENAME"
}
