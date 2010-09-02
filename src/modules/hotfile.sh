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

MODULE_HOTFILE_REGEXP_URL="^http://\(www\.\)\?hotfile\.com/"
MODULE_HOTFILE_DOWNLOAD_OPTIONS=""
MODULE_HOTFILE_UPLOAD_OPTIONS=
MODULE_HOTFILE_LIST_OPTIONS=
MODULE_HOTFILE_DOWNLOAD_CONTINUE=no

# Output an hotfile.com file download URL (anonymous, NOT PREMIUM)
# $1: HOTFILE_URL
# stdout: real file download link
hotfile_download() {
    set -e
    eval "$(process_options hotfile "$MODULE_HOTFILE_DOWNLOAD_OPTIONS" "$@")"

    URL="${1}&lang=en"
    BASE_URL='http://hotfile.com'
    COOKIES=$(create_tempfile)

    # Warning message
    log_notice "# IMPORTANT: Hotfile sometimes asks the user to solve a reCaptcha."
    log_notice "# If this is the case, this module won't able to download the file."
    log_notice "# Do not file this as a bug, reCaptcha is virtually un-breakable."

    while retry_limit_not_reached || return 3; do
        WAIT_HTML=$(curl -c $COOKIES "$URL")

        if match 'hotfile\.com\/list\/' "$URL"; then
            log_error "This is a directory list, use plowlist!"
            rm -f $COOKIES
            return 1
        fi

        if match '404 - Not Found' "$WAIT_HTML"; then
            log_debug "File not found"
            rm -f $COOKIES
            return 254
        fi

        local SLEEP=$(echo "$WAIT_HTML" | parse 'timerend=d.getTime()' '+\([[:digit:]]\+\);') ||
            { log_error "can't get sleep time"; return 1; }

        if test "$CHECK_LINK"; then
            rm -f $COOKIES
            return 255
        fi

        # Send (post) form
        local FORM_HTML=$(grep_form_by_name "$WAIT_HTML" 'f')
        local form_url=$(echo "$FORM_HTML" | parse_form_action)
        local form_action=$(echo "$FORM_HTML" | parse_form_input_by_name 'action')
        local form_tm=$(echo "$FORM_HTML" | parse_form_input_by_name 'tm')
        local form_tmhash=$(echo "$FORM_HTML" | parse_form_input_by_name 'tmhash')
        local form_wait=$(echo "$FORM_HTML" | parse_form_input_by_name 'wait')
        local form_waithash=$(echo "$FORM_HTML" | parse_form_input_by_name 'waithash')
        local form_upidhash=$(echo "$FORM_HTML" | parse_form_input_by_name 'upidhash')

        SLEEP=$((SLEEP / 1000))
        wait $((SLEEP)) seconds || return 2

        WAIT_HTML2=$(curl -b $COOKIES --data "action=${form_action}&tm=${form_tm}&tmhash=${form_tmhash}&wait=${form_wait}&waithash=${form_waithash}&upidhash=${form_upidhash}" \
            "${BASE_URL}${form_url}") || return 1

        # Direct download (no captcha)
        if match 'Click here to download' "$WAIT_HTML2"; then
            local LINK=$(echo "$WAIT_HTML2" | parse 'Click here to download<\/a>' '<a href="\([^"]*\)' 2>/dev/null)
            FILEURL=$(curl -b $COOKIES --include "$LINK" | grep_http_header_location)
            echo "$FILEURL"
            echo
            echo "$COOKIES"
            return 0
        elif match 'You reached your hourly traffic limit' "$WAIT_HTML2"; then
            # grep 2nd occurrence of "timerend=d.getTime()+<number>" (function starthtimer)
            local WAIT_TIME=$(echo "$WAIT_HTML2" | sed -n '/starthtimer/,$p' | parse 'timerend=d.getTime()' '+\([[:digit:]]\+\);') ||
                { log_error "can't get wait time"; return 1; }
            WAIT_TIME=$((WAIT_TIME / 60000))
            wait $((WAIT_TIME)) minutes || return 2
            continue

        # Captcha page
        # Main engine: http://api.recaptcha.net/js/recaptcha.js
        elif match 'api\.recaptcha\.net' "$WAIT_HTML2"
        then
            local FORM2_HTML=$(grep_form_by_order "$WAIT_HTML2" 2)
            local form2_url=$(echo "$FORM2_HTML" | parse_form_action)
            local form2_action=$(echo "$FORM2_HTML" | parse_form_input_by_name 'action')
            local form2_resp_field=$(echo "$FORM2_HTML" | parse_form_input_by_name 'recaptcha_response_field')
            local repatcha_js_vars=$(echo "$FORM2_HTML" | parse_attr 'recaptcha.net\/challenge?k=' 'src')

            # http://api.recaptcha.net/challenge?k=<site key>
            log_debug "reCaptcha URL: $repatcha_js_vars"
            VARS=$(curl -L "$repatcha_js_vars")
            local server=$(echo "$VARS" | parse 'server' "server:'\([^']*\)'" 2>/dev/null)
            local challenge=$(echo "$VARS" | parse 'challenge' "challenge:'\([^']*\)'" 2>/dev/null)

            # Image dimension: 300x57
            FILENAME="/tmp/recaptcha-${challenge:0:16}.jpg"
            curl "${server}image?c=${challenge}" -o $FILENAME
            log_debug "Captcha image local filename: $FILENAME"

            # TODO: display image and prompt for captcha word


            log_error "Captcha page, give up!"
            break

        else
            log_error "Unknown state, give up!"
            break
        fi
    done

    rm -f $COOKIES
    return 1
}

# List a hotfile shared file folder URL
# $1: HOTFILE_URL
# stdout: list of links
hotfile_list() {
    set -e
    eval "$(process_options hotfile "$MODULE_HOTFILE_LIST_OPTIONS" "$@")"
    URL=$1

    if ! match 'hotfile\.com\/list\/' "$URL"; then
        log_error "This is not a directory list"
        return 1
    fi

    PAGE=$(curl "$URL" | grep 'hotfile.com/dl/')

    if test -z "$PAGE"; then
        log_error "Wrong directory list link"
        return 1
    fi

    # First pass : print debug message
    echo "$PAGE" | while read LINE; do
        FILENAME=$(echo "$LINE" | parse 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILENAME"
    done

    # Second pass : print links (stdout)
    echo "$PAGE" | while read LINE; do
        LINK=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$LINK"
    done

    return 0
}
