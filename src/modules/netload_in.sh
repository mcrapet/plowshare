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

MODULE_NETLOAD_IN_REGEXP_URL="^http://\(www\.\)\?netload.in/"
MODULE_NETLOAD_IN_DOWNLOAD_OPTIONS=""
MODULE_NETLOAD_IN_UPLOAD_OPTIONS=""
MODULE_NETLOAD_IN_DOWNLOAD_CONTINUE=no

# Output an netload.in file download URL (anonymous, NOT PREMIUM)
#
# netload_in_download NETLOAD_IN_URL
#
netload_in_download() {
    set -e
    eval "$(process_options uploaded_to "$MODULE_NETLOAD_IN_DOWNLOAD_CONTINUE" "$@")"

    URL=$1
    BASE_URL="http://netload.in"
    COOKIES=$(create_tempfile)

    local try=0
    while retry_limit_not_reached || return 3; do
        ((try++))
        WAIT_URL=$(curl --location -c $COOKIES "$URL" |\
            parse '<div class="Free_dl">' '><a href="\([^"]*\)' 2>/dev/null) ||
            { error "file not found"; return 254; }

        test "$CHECK_LINK" && return 255

        WAIT_URL="$BASE_URL/${WAIT_URL//&amp;/&}"
        WAIT_HTML=$(curl -b $COOKIES $WAIT_URL)
        WAIT_TIME=$(echo "$WAIT_HTML" |\
            parse 'type="text\/javascript">countdown' "countdown(\([[:digit:]]*\),'change()')" 2>/dev/null)

        if test -n "$WAIT_TIME"; then
            countdown $((WAIT_TIME / 100)) 5 seconds 1 || return 2
        fi

        CAPTCHA_URL=$(echo $WAIT_HTML | parse '<img style="vertical-align' 'src="\([^"]*\)" alt="Sicherheitsbild"')
        CAPTCHA_URL="$BASE_URL/$CAPTCHA_URL"

        debug "Try $try:"

        CAPTCHA=$(curl -b $COOKIES "$CAPTCHA_URL" | perl $LIBDIR/strip_single_color.pl |
                convert - -quantize gray -colors 32 -blur 40% -contrast-stretch 6% -compress none -depth 8 tif:- |
                show_image_and_tee | ocr digit | sed "s/[^0-9]//g") ||
                { error "error running OCR"; return 1; }

        debug "Decoded captcha: $CAPTCHA"

        if [ "${#CAPTCHA}" -ne 4 ]; then
            debug "Captcha length invalid"
            continue
        fi

        # Send (post) form
        local form_url=$(echo $WAIT_HTML | parse 'form method=' 'action="\([^"]*\)' 2>/dev/null)
        local form_fid=$(echo $WAIT_HTML | parse '<input name="file_id"' 'type="hidden"[[:space:]]\+value="\([^"]*\)' 2>/dev/null)

        WAIT_HTML2=$(curl -l -b $COOKIES --data "file_id=${form_fid}&captcha_check=${CAPTCHA}&start=" "$BASE_URL/$form_url")

        $(match '\(class="InPage_Error"\)' "$WAIT_HTML2") &&
            { debug "Error (bad captcha), retry"; continue; }

        debug "Correct captcha!"

        WAIT_TIME2=$(echo $WAIT_HTML2 |\
            parse 'type="text\/javascript">countdown' "countdown(\([[:digit:]]*\),'change()')" 2>/dev/null)

        if [ -n "$WAIT_TIME2" ]
        then
            if [[ $WAIT_TIME2 -gt 10000 ]]
            then
                debug "Download limit reached!"
                countdown $((WAIT_TIME2 / 100)) 40 seconds 1 || return 2
            else
                # Supress this wait will lead to a 400 http error (bad request)
                countdown $((WAIT_TIME2 / 100)) 5 seconds 1 || return 2
                break
            fi
        fi

    done

    rm -f $COOKIES

    FILENAME=$(echo $WAIT_HTML2 |\
        parse '<h2>[Dd]ownload:' '<h2>[Dd]ownload:[[:space:]]*\([^<]*\)' 2>/dev/null)
    FILE_URL=$(echo $WAIT_HTML2 |\
        parse '<a class="Orange_Link"' 'Link" href="\(http[^"]*\)')

    echo $FILE_URL
    test -n "$FILENAME" && echo "$FILENAME"
    return 0
}
