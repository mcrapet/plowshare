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

MODULE_HOTFILE_REGEXP_URL="^http://\(www\.\)\?hotfile.com/"
MODULE_HOTFILE_DOWNLOAD_OPTIONS=""
MODULE_HOTFILE_UPLOAD_OPTIONS=""
MODULE_HOTFILE_DOWNLOAD_CONTINUE=no

# Output an hotfile.com file download URL (anonymous, NOT PREMIUM)
#
# hotfile_download HOTFILE_URL
#
hotfile_download() {
    set -e
    eval "$(process_options x7_to "$MODULE_HOTFILE_DOWNLOAD_CONTINUE" "$@")"

    URL=$1
    BASE_URL='http://hotfile.com'
    COOKIES=$(create_tempfile)

    # Warning message
    debug "##"
    debug "# Important note: reCaptcha is not handled here."
    debug "# As captcha challenge request is random and/or linked to specific url,"
    debug "# some link could be never downloaded."
    debug "##"

    while retry_limit_not_reached || return 3; do
        WAIT_HTML=$(curl -c $COOKIES "$URL")

        $(match '\(REGULAR DOWNLOAD\)' "$WAIT_HTML") ||
            { error "File not found"; return 254; }

        local SLEEP=$(echo "$WAIT_HTML" | parse 'timerend=d.getTime()' '+\([[:digit:]]\+\);') ||
            { error "can't get sleep time"; return 1; }

        test "$CHECK_LINK" && return 255

        SLEEP=$((SLEEP / 1000))
        countdown $((SLEEP)) 2 seconds 1 || return 2

        # Send (post) form
        local form_url=$(echo "$WAIT_HTML" | parse '<form .*name=f>' 'action="\([^"]*\)' 2>/dev/null)
        local form_action=$(echo "$WAIT_HTML" | parse '<input [^ ]* name=action' "value=\([^>]*\)" 2>/dev/null)
        local form_tm=$(echo "$WAIT_HTML" | parse '<input [^ ]* name=tm' "value=\([^>]*\)" 2>/dev/null)
        local form_tmhash=$(echo "$WAIT_HTML" | parse '<input [^ ]* name=tmhash' "value=\([^>]*\)" 2>/dev/null)
        local form_wait=$(echo "$WAIT_HTML" | parse '<input [^ ]* name=wait' "value=\([^>]*\)" 2>/dev/null)
        local form_waithash=$(echo "$WAIT_HTML" | parse '<input [^ ]* name=waithash' "value=\([^>]*\)" 2>/dev/null)

        # We want "Content-Type: application/x-www-form-urlencoded"
        WAIT_HTML2=$(curl -b $COOKIES --data "action=${form_action}&tm=${form_tm}&tmhash=${form_tmhash}&wait=${form_wait}&waithash=${form_waithash}" \
            "$BASE_URL/$form_url") || return 1

        # Direct download (no captcha)
        if match '\(Click here to download\)' "$WAIT_HTML2"
        then
            rm -f $COOKIES
            local link=$(echo "$WAIT_HTML2" | parse 'Click here to download<\/a>' '<a href="\([^"]*\)' 2>/dev/null)

            echo $link
            return 0

        elif match '\(You reached your hourly traffic limit\)' "$WAIT_HTML2"
        then
            # grep 2nd occurrence of "timerend=d.getTime()+<number>" (function starthtimer)
            local WAIT_TIME=$(echo "$WAIT_HTML2" | sed -n '/starthtimer/,$p' | parse 'timerend=d.getTime()' '+\([[:digit:]]\+\);') ||
                { error "can't get wait time"; return 1; }
            WAIT_TIME=$((WAIT_TIME / 60000))
            countdown $((WAIT_TIME)) 1 minutes 60 || return 2
            continue

        # Captcha page
        # Main engine: http://api.recaptcha.net/js/recaptcha.js
        elif match '\(recaptcha\.net\)' "$WAIT_HTML2"
        then
            local form2_url=$(echo "$WAIT_HTML2" | parse '<form .*\/dl\/' 'action="\([^"]*\)' 2>/dev/null)
            local form2_action=$(echo "$WAIT_HTML2" | parse '<input [^ ]* name="action"' 'value="\([^"]*\)' 2>/dev/null)
            local form2_resp_field=$(echo "$WAIT_HTML2" | parse '<input [^ ]* name="recaptcha_response_field' 'value="\([^"]*\)' 2>/dev/null)
            local repatcha_js_vars=$(echo "$WAIT_HTML2" | parse 'recaptcha.net\/challenge?k=' 'src="\([^"]*\)' 2>/dev/null)

            # http://api.recaptcha.net/challenge?k=<site key>
            VARS=$(curl "$repatcha_js_vars")
            local server=$(echo "$VARS" | parse 'server' "'\([^']*\)'" 2>/dev/null)
            local challenge=$(echo "$VARS" | parse 'challenge' "'\([^']*\)'" 2>/dev/null)

            # Image dimension: 300x57
            #$(curl "${server}image?c=${challenge}" -o "recaptcha-${challenge:0:16}.jpg")
            #echo "$VARS" "$WAIT_HTML2" >/tmp/a

            debug "Captcha page, give up!"
            break

        else
            debug "Unknown state, give up!"
            break
        fi
    done

    rm -f $COOKIES
    return 1
}
