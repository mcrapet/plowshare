# Plowshare freakshare.com module
# Copyright (c) 2012-2013 Plowshare team
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

MODULE_FREAKSHARE_REGEXP_URL='http://\(www\.\)\?freakshare\.com/'

MODULE_FREAKSHARE_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_FREAKSHARE_DOWNLOAD_RESUME=no
MODULE_FREAKSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_FREAKSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FREAKSHARE_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_FREAKSHARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_FREAKSHARE_PROBE_OPTIONS=""

# Static function. Proceed with login (free or premium)
freakshare_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT L

    LOGIN_DATA='user=$USER&pass=$PASSWORD&submit=Login'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.html" -b "$COOKIE_FILE") || return

    # If login successful we get "login" entry in cookie file
    # and HTTP redirection (Location: $BASE_URL)
    L=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -z "$L" ]; then
        # <p class="error">Wrong Username or Password!</p>
        return $ERR_LOGIN_FAILED
    fi
}

# Output an freakshare.com file download URL (anonymous or premium)
# $1: cookie file
# $2: freakshare.com url
# stdout: real file download link
freakshare_download() {
    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://freakshare.com'
    local WAIT_HTML SLEEP

    if match 'freakshare\.com/list/' "$URL"; then
        log_error 'This is a directory list, use plowlist!'
        return $ERR_FATAL
    fi

    # Set english language (server side information, identified by PHPSESSID)
    curl -o /dev/null -c "$COOKIEFILE" \
        "$BASE_URL/index.php?language=EN" || return

    if [ -n "$AUTH_FREE" ]; then
        freakshare_login "$AUTH_FREE" "$COOKIEFILE" "$BASE_URL" || return
    fi

    WAIT_HTML=$(curl -b "$COOKIEFILE" "$URL") || return

    if match '404 - Not Found\|or is deleted\|This file does not exist!' "$WAIT_HTML"; then
        return $ERR_LINK_DEAD
    # Anonymous users only get this. We don't know how much time to wait :(
    elif match 'Your Traffic is used up for today!' "$WAIT_HTML"; then
        echo 3600
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi


    SLEEP=$(echo "$WAIT_HTML" | parse 'time' '=\ \([[:digit:]]\+\)\.0;') || return

    # Send (post) form
    local FORM_HTML FORM_URL FORM_SECTION FORM_DID
    FORM_HTML=$(grep_form_by_order "$WAIT_HTML" 2) || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_SECTION=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'section')
    FORM_DID=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'did')

    wait $((SLEEP)) seconds || return

    WAIT_HTML=$(curl -b "$COOKIEFILE" \
        --data "section=${FORM_SECTION}&did=${FORM_DID}" "$FORM_URL") || return

    if match 'Your Traffic is used up for today!' "$WAIT_HTML"; then
        # grep 2nd occurrence of "timerend=d.getTime()+<number>" (function starthtimer)
        WAIT_TIME=$(echo "$WAIT_HTML" | parse 'time' '=\ \([[:digit:]]\+\)\.0;')
        echo $WAIT_TIME
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match 'api\.recaptcha\.net' "$WAIT_HTML"; then
        local FORM2_HTML FORM2_URL FORM2_SECTION FROM2_DID PAGE
        FORM2_HTML=$(grep_form_by_order "$WAIT_HTML" 1) || return
        FORM2_URL=$(echo "$FORM2_HTML" | parse_form_action) || return
        FORM2_SECTION=$(echo "$FORM2_HTML" | parse_form_input_by_name_quiet 'section')
        FORM2_DID=$(echo "$FORM2_HTML" | parse_form_input_by_name_quiet 'did')

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6Lftl70SAAAAAItWJueKIVvyG0QfLgmAgzKgTbDT'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        PAGE=$(curl -i -b "$COOKIEFILE" \
            -d "recaptcha_challenge_field=$CHALLENGE" \
            -d "recaptcha_response_field=$WORD" \
            -d "section=$FORM2_SECTION" \
            -d "did=$FORM2_DID" \
            "$FORM2_URL") || return

        if match 'Wrong Captcha!' "$PAGE"; then
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug 'correct captcha'

        # Sorry, you cant download more then 1 files at time.
        if match 'download more then.*files at time.' "$PAGE"; then
            log_error 'No parallel download allowed'
            echo 120
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        FILE_URL=$(echo "$PAGE" | grep_http_header_location) || return
        FILE_NAME=$(basename_file "$FORM2_URL")

        echo "$FILE_URL"
        echo "${FILE_NAME%.html}"
        return 0
    fi

    log_error 'Unknown Status'
    return $ERR_FATAL
}

# Upload a file to freakshare
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download_url
freakshare_upload() {
    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://freakshare.com'

    local PAGE URL FORM_HTML FORM_ACTION
    local FORM_APC_PROGRESS FORM_APC_USERGRP FORM_UPLOAD_ID

    # Set english language (server side information, identified by PHPSESSID)
    curl -o /dev/null -c "$COOKIE_FILE" \
        "$BASE_URL/index.php?language=EN" || return

    if [ -n "$AUTH" ]; then
        freakshare_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return

    FORM_HTML=$(grep_form_by_id "$PAGE" 'uploadform') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_APC_PROGRESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'APC_UPLOAD_PROGRESS')
    FORM_APC_USERGRP=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'APC_UPLOAD_USERGROUP')
    FORM_UPLOAD_ID=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'UPLOAD_IDENTIFIER')

    # Empty file field is required (does not work without it)
    PAGE=$(curl_with_log -i \
        -e "$BASE_URL" \
        -F "APC_UPLOAD_PROGRESS=$FORM_APC_PROGRESS" \
        -F "APC_UPLOAD_USERGROUP=$FORM_APC_USERGRP" \
        -F "UPLOAD_IDENTIFIER=$FORM_UPLOAD_ID" \
        -F "file[]=@/dev/null;filename=" \
        -F "file[]=@$FILE;filename=$DESTFILE" \
        "$FORM_ACTION?X-Progress-ID=undefined$(random h 32)") || return

    if match '^HTTP/1.1 404 Not Found' "$PAGE"; then
        echo 600
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    URL=$(echo "$PAGE" | grep_http_header_location) || return
    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

    echo "$PAGE" | parse_attr '/files/' value || return
    echo "$PAGE" | parse_attr '/delete/' value || return
}

# Probe a download URL
# $1: cookie file
# $2: freakshare url
# $3: requested capability list
# stdout: 1 capability per line
freakshare_probe() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    # Set english language (server side information, identified by PHPSESSID)
    curl -o /dev/null -c "$COOKIE_FILE" \
        'http://freakshare.com/index.php?language=EN' || return

    PAGE=$(curl -L -b "$COOKIE_FILE" "$URL") || return

    if match '404 - Not Found\|or is deleted\|This file does not exist!' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '=.box_heading' '">\(.*\)[[:space:]]-[[:space:]]' <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '=.box_heading' '[[:space:]]-[[:space:]]\([^<]*\)' <<< "$PAGE")
        translate_size "${FILE_SIZE%yte}" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
