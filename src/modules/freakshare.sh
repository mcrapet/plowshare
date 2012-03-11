#!/bin/bash
#
# freakshare.com module
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

MODULE_FREAKSHARE_REGEXP_URL="http://\(www\.\)\?freakshare\.com/"

MODULE_FREAKSHARE_DOWNLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free account"
MODULE_FREAKSHARE_DOWNLOAD_RESUME=no
MODULE_FREAKSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

# Output an freakshare.com file download URL (anonymous or premium)
# $1: cookie file
# $2: freakshare.com url
# stdout: real file download link
freakshare_download() {
    eval "$(process_options freakshare "$MODULE_FREAKSHARE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://freakshare.com'
    local WAIT_HTML SLEEP

    if match 'freakshare\.com\/list\/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return $ERR_FATAL
    fi

    # Set english language (server side information, identified by PHPSESSID)
    curl -o /dev/null -c "$COOKIEFILE" \
        "http://freakshare.com/index.php?language=EN" || return

    if [ -n "$AUTH_FREE" ]; then
        local LOGIN_DATA LOGIN_RESULT L

        LOGIN_DATA='user=$USER&pass=$PASSWORD&submit=Login'
        LOGIN_RESULT=$(post_login "$AUTH_FREE" "$COOKIEFILE" "$LOGIN_DATA" \
            "$BASE_URL/login.html" "-b $COOKIEFILE") || return

        # If login successful we get "login" entry in cookie file
        # and HTTP redirection (Location: $BASE_URL)
        L=$(parse_cookie_quiet 'login' < "$COOKIEFILE")
        if [ -z "$L" ]; then
            # <p class="error">Wrong Username or Password!</p>
           return $ERR_LOGIN_FAILED
        fi
    fi

    WAIT_HTML=$(curl -b "$COOKIEFILE" "$URL") || return

    if match '404 - Not Found\|or is deleted\|This file does not exist!' "$WAIT_HTML"; then
        return $ERR_LINK_DEAD

    # Anonymous users only get this. We don't know how much time to wait :(
    elif match 'Your Traffic is used up for today!' "$WAIT_HTML"; then
        echo 3600
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    SLEEP=$(echo "$WAIT_HTML" | parse 'time' '=\ \([[:digit:]]\+\)\.0;') ||
            { log_error "can't get sleep time"; return $ERR_FATAL; }

    # Send (post) form
    local FORM_HTML FORM_URL FORM_SECTION FORM_DID
    FORM_HTML=$(grep_form_by_order "$WAIT_HTML" 2)
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action)
    FORM_SECTION=$(echo "$FORM_HTML" | parse_form_input_by_name 'section')
    FORM_DID=$(echo "$FORM_HTML" | parse_form_input_by_name 'did')

    wait $((SLEEP)) seconds || return

    WAIT_HTML=$(curl -b "$COOKIEFILE" \
        --data "section=${FORM_SECTION}&did=${FORM_DID}" "$FORM_URL") || return

    if match 'Your Traffic is used up for today!' "$WAIT_HTML"; then
        # grep 2nd occurrence of "timerend=d.getTime()+<number>" (function starthtimer)
        WAIT_TIME=$(echo "$WAIT_HTML" | parse 'time' '=\ \([[:digit:]]\+\)\.0;')
        echo $WAIT_TIME
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match 'api\.recaptcha\.net' "$WAIT_HTML"; then
        local FORM2_HTML FORM2_URL FORM2_SECTION FROM2_DID HTMLPAGE
        FORM2_HTML=$(grep_form_by_order "$WAIT_HTML" 1) || return
        FORM2_URL=$(echo "$FORM2_HTML" | parse_form_action) || return
        FORM2_SECTION=$(echo "$FORM2_HTML" | parse_form_input_by_name 'section')
        FORM2_DID=$(echo "$FORM2_HTML" | parse_form_input_by_name 'did')

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6Lftl70SAAAAAItWJueKIVvyG0QfLgmAgzKgTbDT'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        HTMLPAGE=$(curl -i -b "$COOKIEFILE" --data \
            "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD&section=$FORM2_SECTION&did=$FORM2_DID" \
            "$FORM2_URL") || return

        if match 'Wrong Code. Please try again.' "$HTMLPAGE"; then
            recaptcha_nack $ID
            log_error "Wrong captcha"
            return $ERR_CAPTCHA
        fi

        recaptcha_ack $ID
        log_debug "correct captcha"

        FILE_URL=$(echo "$HTMLPAGE" | grep_http_header_location) || return
        FILE_NAME=$(basename_file "$FORM2_URL")

        echo "$FILE_URL"
        echo "${FILE_NAME%.html}"
        return 0
    fi

    log_error "Unknown Status"
    return $ERR_FATAL
}
