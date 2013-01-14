#!/bin/bash
#
# turbobit.net module
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

MODULE_TURBOBIT_REGEXP_URL="http://\(www\.\)\?turbobit\.net/"

MODULE_TURBOBIT_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_TURBOBIT_DOWNLOAD_RESUME=yes
MODULE_TURBOBIT_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_TURBOBIT_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_TURBOBIT_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_TURBOBIT_UPLOAD_REMOTE_SUPPORT=no

MODULE_TURBOBIT_DELETE_OPTIONS=""

# Static function. Proceed with login (free or premium)
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
turbobit_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3
    local LOGIN_DATA PAGE STATUS EMAIL TYPE

    # Force page in English
    LOGIN_DATA='user[login]=$USER&user[pass]=$PASSWORD&user[submit]=Login'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/user/login" -b 'user_lang=en' --location) || return

    STATUS=$(parse_cookie_quiet 'user_isloggedin' < "$COOKIE_FILE")
    [ "$STATUS" = '1' ] || return $ERR_LOGIN_FAILED

    # determine user mail and account type
    EMAIL=$(echo "$PAGE" | parse ' user-name' \
        '^[[:blank:]]*\([^[:blank:]]\+\)[[:blank:]]' 3) || return

    if match '<u>Turbo Access</u> denied' "$PAGE"; then
        TYPE='free'
    elif match '<u>Turbo Access</u> to' "$PAGE"; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    log_debug "Successfully logged in as $TYPE member '$EMAIL'"
    echo "$TYPE"
    return 0
}

# Output a turbobit file download URL
# $1: cookie file
# $2: turbobit url
# stdout: real file download link
turbobit_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://turbobit.net'
    local FILE_ID FREE_URL ACCOUNT FILE_URL FILE_NAME PAGE WAIT PAGE_LINK

    PAGE=$(curl -c "$COOKIE_FILE" -b 'user_lang=en' "$URL") || return

    match 'File not found' "$PAGE" && return $ERR_LINK_DEAD
    [ -n "$CHECK_LINK" ] && return 0

    FILE_NAME=$(echo "$PAGE" | parse 'Download file:' '>\([^<]\+\)<' 1) || return

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(turbobit_login "$AUTH" "$COOKIE_FILE" \
            "$BASE_URL") || return

        if [ "$ACCOUNT" = 'premium' ]; then
            PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return
            FILE_URL=$(echo "$PAGE" | parse_attr '/redirect/' 'href') || return

            # Redirects 3 times...
            FILE_URL=$(curl -b "$COOKIEFILE" --head "$FILE_URL" | \
                grep_http_header_location) || return
            FILE_URL=$(curl -b "$COOKIEFILE" --head "$FILE_URL" | \
                grep_http_header_location) || return

            echo "$FILE_URL"
            echo "$FILE_NAME"
            return 0
        fi
    fi

    # Get ID from URL:
    # http://turbobit.net/hsclfbvorabc/full.filename.avi.html
    # http://turbobit.net/hsclfbvorabc.html
    FILE_ID=$(echo "$URL" | parse_quiet '.html' '.net/\([^/.]*\)')

    # http://turbobit.net/download/free/hsclfbvorabc
    if [ -z "$FILE_ID" ]; then
        FILE_ID=$(echo "$URL" | parse_quiet '/download/free/' 'free/\([^/]*\)')
    fi

    if [ -z "$FILE_ID" ]; then
        log_error 'Could not find file ID. URL invalid.'
        return $ERR_FATAL
    fi

    FREE_URL="http://turbobit.net/download/free/$FILE_ID"
    PAGE=$(curl -b "$COOKIE_FILE" "$FREE_URL") || return

    # <h1>Our service is currently unavailable in your country.</h1>
    if match 'service is currently unavailable in your country' "$PAGE"; then
        log_error 'Service not available in your country'
        return $ERR_FATAL
    fi

    # reCaptcha page
    if match 'api\.recaptcha\.net' "$PAGE"; then

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LcTGLoSAAAAAHCWY9TTIrQfjUlxu6kZlTYP50_c'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        PAGE=$(curl -b "$COOKIE_FILE" --referer "$FREE_URL"   \
            -d 'captcha_subtype=' -d 'captcha_type=recaptcha' \
            -d "recaptcha_challenge_field=$CHALLENGE"         \
            -d "recaptcha_response_field=$WORD"               \
            "$FREE_URL") || return

        if match 'Incorrect, try again!' "$PAGE"; then
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug 'Correct captcha'

    # Alternative captcha. Can be one of the following:
    # - Securimage: http://www.phpcaptcha.org
    # - Kohana: https://github.com/Yahasana/Kohana-Captcha
    elif match 'onclick="updateCaptchaImage()"' "$PAGE"; then
        local CAPTCHA_URL CAPTCHA_TYPE CAPTCHA_SUBTYPE CAPTCHA_IMG

        CAPTCHA_URL=$(echo "$PAGE" | parse_attr 'id="captcha-img"' 'src') || return
        CAPTCHA_TYPE=$(echo "$PAGE" | parse_attr 'captcha_type' value) || return
        CAPTCHA_SUBTYPE=$(echo "$PAGE" | parse_attr_quiet 'captcha_subtype' value)

        # Get new image captcha (cookie is mandatory)
        CAPTCHA_IMG=$(create_tempfile '.png') || return
        curl -b "$COOKIE_FILE" -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || return

        local WI WORD ID
        WI=$(captcha_process "$CAPTCHA_IMG") || return
        { read WORD; read ID; } <<<"$WI"
        rm -f "$CAPTCHA_IMG"

        log_debug "Decoded captcha: $WORD"

        PAGE=$(curl -b "$COOKIE_FILE" --referer "$FREE_URL" \
            -d "captcha_subtype=$CAPTCHA_SUBTYPE"    \
            -d "captcha_type=$CAPTCHA_TYPE"          \
            -d "captcha_response=$(lowercase $WORD)" \
            "$FREE_URL") || return

        if match 'Incorrect, try again!' "$PAGE"; then
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug 'Correct captcha'
    fi

    # This code must stay below captcha
    # You have reached the limit of connections
    # From your IP range the limit of connections is reached
    if match 'the limit of connections' "$PAGE"; then
        WAIT=$(echo "$PAGE" | parse 'limit: ' \
            'limit: \([[:digit:]]\+\),') || return

        log_error 'Limit of connections reached'
        echo $WAIT
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # This code must stay below captcha
    # Unable to Complete Request
    # The site is temporarily unavailable during upgrade process
    if match 'Unable to Complete Request\|temporarily unavailable' "$PAGE"; then
        log_error 'Site maintainance'
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Wait time after correct captcha
    WAIT=$(echo "$PAGE" | parse 'minLimit :' \
        ': \([[:digit:][:blank:]+-]\+\),') || return
    wait $((WAIT + 1)) || return

    PAGE_LINK=$(echo "$PAGE" | parse '/download/' '"\([^"]\+\)"') || return

    # Get the page containing the file url
    PAGE=$(curl -b "$COOKIE_FILE" --referer "$FREE_URL" \
        --header 'X-Requested-With: XMLHttpRequest'     \
        "$BASE_URL/$PAGE_LINK") || return

    # Sanity check
    if match 'code-404\|text-404' "$PAGE"; then
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr '/download/redirect/' 'href') || return
    FILE_URL="$BASE_URL$FILE_URL"

    # Redirects 3 times...
    FILE_URL=$(curl -b "$COOKIEFILE" --head "$FILE_URL" | \
        grep_http_header_location) || return
    FILE_URL=$(curl -b "$COOKIEFILE" --head "$FILE_URL" | \
        grep_http_header_location) || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to turbobit
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: turbobit download link + delete link
turbobit_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://turbobit.net'
    local PAGE UP_URL APP_TYPE FORM_UID FILE_SIZE MAX_SIZE
    local JSON FILE_ID DELETE_ID

    if [ -n "$AUTH" ]; then
        turbobit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" > /dev/null || return
    fi

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'user_lang=en' "$BASE_URL") || return

    UP_URL=$(echo "$PAGE" | parse 'flashvars=' 'urlSite=\([^&"]\+\)') || return
    APP_TYPE=$(echo "$PAGE" | parse 'flashvars=' 'apptype=\([^&"]\+\)') || return
    MAX_SIZE=$(echo "$PAGE" | parse 'flashvars=' 'maxSize=\([[:digit:]]\+\)') || return

    log_debug "Upload URL: $UP_URL"
    log_debug "App Type: $APP_TYPE"
    log_debug "Max size: $MAX_SIZE"

    SIZE=$(get_filesize "$FILE") || return
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$AUTH" ]; then
        local USER_ID

        USER_ID=$(echo "$PAGE" | parse 'flashvars=' 'userId=\([^&"]\+\)') || return
        log_debug "User ID: $USER_ID"
        FORM_UID="-F user_id=$USER_ID"
    fi

    # Cookie to error message in English
    JSON=$(curl_with_log --user-agent 'Shockwave Flash' -b "$COOKIE_FILE" -b 'user_lang=en'\
        -F "Filename=$DEST_FILE" -F 'id=null' \
        -F "apptype=$APP_TYPE" -F 'stype=null' \
        -F "Filedata=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        -F 'Upload=Submit Query' \
        $FORM_UID \
        "$UP_URL") || return

    if ! match_json_true 'result' "$JSON"; then
        local MESSAGE

        MESSAGE=$(echo "$JSON" | parse_json 'message') || return
        log_error "Unexpected remote error: $MESSAGE"
        return $ERR_FATAL
    fi

    FILE_ID=$(echo "$JSON" | parse_json id) || return
    log_debug "File ID: $FILE_ID"

    # get info page for file
    PAGE=$(curl --get -b "$COOKIEFILE" \
        -d '_search=false' -d "nd=$(date +%s000)" \
        -d 'rows=20' -d 'page=1'   \
        -d 'sidx=id' -d 'sord=asc' \
        "$BASE_URL/newfile/gridFile/$FILE_ID") || return

    DELETE_ID=$(echo "$PAGE" | parse '' 'null,null,"\([^"]\+\)"')

    echo "$BASE_URL/$FILE_ID.html"
    [ -n "$DELETE_ID" ] && echo "$BASE_URL/delete/file/$FILE_ID/$DELETE_ID"
}

# Delete a file on turbobit
# $1: cookie file (unused here)
# $2: delete link
turbobit_delete() {
    local PAGE URL

    PAGE=$(curl -b 'user_lang=en' "$2") || return

    # You can't remove this file - code is incorrect
    if match 'code is incorrect' "$PAGE"; then
        log_error "bad deletion code"
        return $ERR_FATAL
    # File was not found. It could possibly be deleted.
    # File not found. Probably it was deleted.
    elif match 'File\( was\)\? not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    URL=$(echo "$PAGE" | parse_attr '>Yes' href) || return
    PAGE=$(curl -b 'user_lang=en' "http://turbobit.net$URL") || return

    # File was deleted successfully
    match 'deleted successfully' "$PAGE" || return $ERR_FATAL
}
