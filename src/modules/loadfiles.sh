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

MODULE_LOADFILES_REGEXP_URL="http://\(\w\+\.\)\?loadfiles\.in/"
MODULE_LOADFILES_DOWNLOAD_OPTIONS=""
MODULE_LOADFILES_UPLOAD_OPTIONS=
MODULE_LOADFILES_DOWNLOAD_CONTINUE=no

# Output a loadfiles file download URL (anonymous, NOT PREMIUM)
#
# loadfiles_download LOADFILES_URL
#
loadfiles_download() {
    set -e
    eval "$(process_options loadfiles "$MODULE_LOADFILES_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    while retry_limit_not_reached || return 3; do
        DATA=$(curl "$URL")

        ERR1='No such file with this filename'
        ERR2='File Not Found'
        echo "$DATA" | grep -q "$ERR1\|$ERR2" &&
            { error "file not found"; return 254; }

        test "$CHECK_LINK" && return 255

        test $(echo "$DATA" | grep 'class="err"' | wc -l) -eq 0 || {
            HOUR=$(echo "$DATA" | parse 'class="err"' 'wait\ \([0-9]\+\)\ hour' 2>/dev/null) || HOUR=0
            MINUTES=$(echo "$DATA" | parse 'class="err"' '\ \([0-9]\+\)\ minutes' 2>/dev/null) || MINUTES=0
            SECONDS=$(echo "$DATA" | parse 'class="err"' '\ \([0-9]\+\)\ seconds')

            debug "You have to wait $HOUR hour, $MINUTES minutes, $SECONDS seconds."
            countdown $((HOUR*3600+$MINUTES*60+$SECONDS)) 10 seconds 1
            continue
        }

        CAPTCHA_URL=$(echo "$DATA" | parse "<img" 'src="\(http:\/\/loadfiles.in\/captchas\/[^.]*.jpg\)"') || return 1
        debug "Captcha URL: $CAPTCHA_URL"

        # The important thing here is to crop exactly around the 4 digits. Otherwise tesseract will find extra digits.
        # Adding "-blur" does not give better results.
        CONVERT_OPTS="-crop 36x14+22+5"

        CAPTCHA=$(curl "$CAPTCHA_URL"  | perl $LIBDIR/strip_grey.pl | convert - ${CONVERT_OPTS} gif:- |
                show_image_and_tee | ocr digit |  sed "s/[^0-9]//g") ||
            { error "error running OCR"; return 1; }

        test "${#CAPTCHA}" -gt 4 && CAPTCHA="${CAPTCHA:0:4}"
        debug "Decoded captcha: $CAPTCHA"

        test "${#CAPTCHA}" -ne 4 &&
            { debug "Capcha length invalid"; continue; }

        local download_form=$(grep_form_by_name "$DATA" 'F1')
        DATA_RAND=$(echo "$download_form" | parse_form_input_by_name 'rand')
        DATA_OP=$(echo "$download_form" | parse_form_input_by_name 'op')
        DATA_ID=$(echo "$download_form" | parse_form_input_by_name 'id')
        DATA_REFERER=""
        DATA_DOWN_SCRIPT="1"
        DATA_METHOD_FREE="Free+Download"
        DATA_BTN_DOWNLOAD="Download+File"
        CDATA="op=${DATA_OP}&id=${DATA_ID}&rand=${DATA_RAND}&referer=${DATA_REFERER}&method_free=${DATA_METHOD_FREE}&\
down_script=${DATA_DOWN_SCRIPT}&btn_download=${DATA_BTN_DOWNLOAD}&code=$CAPTCHA"

        WAIT_TIME=$(echo "$DATA" | parse '"countdown"' '>\([0-9]*\)<\/span>')

        countdown $((WAIT_TIME+1)) 10 seconds 1

        # send post and get header
        FINAL_PAGE=$(curl -i --data "$CDATA" "$URL")

        test $(echo "$FINAL_PAGE" | grep 'class="err"' | wc -l) -eq 0 || {
            debug "Wrong captcha"; continue;
        }

        # since the response is a 302 (MOVED), get the new file location
        FILE_URL=$(echo "$FINAL_PAGE" | grep_http_header_location)

        if [ -n "$FILE_URL" ]; then
            debug "Correct captcha!"
            break
        fi
    done

    echo "$FILE_URL"
}
