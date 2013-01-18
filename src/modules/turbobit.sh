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

# Check for dead link
# $1: page
is_dead_turbobit(){
    match 'File not found' "$1" && return $ERR_LINK_DEAD
    return 0
}

# Output a turbobit file download URL
# $1: cookie file
# $2: turbobit url
# stdout: real file download link
turbobit_download() {
    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://turbobit.net'

    local ID_FILE FREE_URL PAGE PART_FILE_URL FILE_URL PAGE_LINK0 PAGE_LINK
    local FILENAME WAIT_TIME WAIT_TIME2 CAPTCHA_IMG
    local JS_URL JS_CODE JS_CODE2 LINK_RAND LINK_HASH

    # Get id from these url formats:
    # http://turbobit.net/hsclfbvorabc/full.filename.avi.html
    # http://turbobit.net/hsclfbvorabc.html
    ID_FILE=$(echo "$URL" | parse_quiet '.html' '.net/\([^/.]*\)')

    # Get id from these url formats:
    # http://turbobit.net/download/free/hsclfbvorabc
    if [ -z "$ID_FILE" ]; then
        ID_FILE=$(echo "$URL" | parse_quiet '/download/free/' 'free/\([^/]*\)')
    fi

    if [ -z "$ID_FILE" ]; then
        log_error "Could not find id in url"
        return $ERR_LINK_DEAD
    fi

    FREE_URL="http://turbobit.net/download/free/$ID_FILE"

    if test -n "$AUTH"; then
        turbobit_login "$AUTH" "$COOKIEFILE" "$BASE_URL" >/dev/null || return
        PAGE=$(curl -b "$COOKIEFILE" "$BASE_URL") || return

        # Premium account
        if match '<u>Turbo Access</u> to' "$PAGE"; then
            PAGE=$(curl -b "$COOKIEFILE" "$URL") || return

            # Check for dead link
            is_dead_turbobit "$PAGE" || return

            FILE_URL=$(echo "$PAGE" | parse_attr '/redirect/' 'href')
            FILE_NAME=$(basename_file "$FILE_URL")

            FILE_URL=$(curl -b "$COOKIEFILE" --include "$FILE_URL" | \
                grep_http_header_location) || return
            FILE_URL=$(curl -b "$COOKIEFILE" --include "$FILE_URL" | \
                grep_http_header_location) || return

            echo "$FILE_URL"
            echo "$FILE_NAME"
            return 0
        fi
        PAGE=$(curl -b "$COOKIEFILE" -c "$COOKIEFILE" "$FREE_URL") || return
    else
        PAGE=$(curl -c "$COOKIEFILE" -b 'user_lang=en' "$FREE_URL") || return
    fi

    # <h1>Our service is currently unavailable in your country.</h1>
    # <h1>Sorry about that.</h1>
    if match 'service is currently unavailable in your country' "$PAGE"; then
        log_error "Service not available for your country"
        return $ERR_FATAL
    fi

    # Check for dead link
    is_dead_turbobit "$PAGE" || return

    test "$CHECK_LINK" && return 0

    detect_javascript || return

    # reCaptcha page
    if match 'api\.recaptcha\.net' "$PAGE"; then

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LcTGLoSAAAAAHCWY9TTIrQfjUlxu6kZlTYP50_c'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        PAGE=$(curl -b "$COOKIEFILE" --data \
            "captcha_subtype=&captcha_type=recaptcha&recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" \
            --referer "$FREE_URL" "$FREE_URL") || return

        if match 'Incorrect, try again!' "$PAGE"; then
            captcha_nack $ID
            log_error "Wrong captcha"
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug "correct captcha"

    # Alternative captcha. Can be one of the following:
    # - Securimage: http://www.phpcaptcha.org
    # - Kohana: https://github.com/Yahasana/Kohana-Captcha
    elif match 'onclick="updateCaptchaImage()"' "$PAGE"; then
        local CAPTCHA_URL CAPTCHA_TYPE CAPTCHA_SUBTYPE

        CAPTCHA_URL=$(echo "$PAGE" | parse_attr 'id="captcha-img"' 'src')
        CAPTCHA_TYPE=$(echo "$PAGE" | parse_attr 'captcha_type' value)
        CAPTCHA_SUBTYPE=$(echo "$PAGE" | parse_attr_quiet 'captcha_subtype' value)

        # Get new image captcha (cookie is mandatory)
        CAPTCHA_IMG=$(create_tempfile '.png') || return
        curl -b "$COOKIEFILE" -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || return

        local WI WORD ID
        WI=$(captcha_process "$CAPTCHA_IMG") || return
        { read WORD; read ID; } <<<"$WI"
        rm -f "$CAPTCHA_IMG"

        log_debug "decoded captcha: $WORD"

        PAGE=$(curl -b "$COOKIEFILE" \
            -d "captcha_subtype=$CAPTCHA_SUBTYPE" \
            -d "captcha_type=$CAPTCHA_TYPE" \
            -d "captcha_response=$(lowercase $WORD)" \
            --referer "$FREE_URL" "$FREE_URL") || return

        if match 'Incorrect, try again!' "$PAGE"; then
            captcha_nack $ID
            log_error "Wrong captcha"
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug "correct captcha"
    fi

    # This code must stay below captcha
    # case: You have reached the limit of connections
    # case: From your IP range the limit of connections is reached
    local ERR1='You have reached the limit of connections'
    local ERR2='From your IP range the limit of connections is reached'
    if match "$ERR1\|$ERR2" "$PAGE"; then
        WAIT_TIME=$(echo "$PAGE" | parse 'limit: ' 'limit: \([^,]*\)') || \
            { log_error "can't get sleep time"; return $ERR_FATAL; }
        echo $WAIT_TIME
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # This code must stay below captcha
    # case: Unable to Complete Request
    # case: The site is temporarily unavailable during upgrade process
    ERR1='Unable to Complete Request'
    ERR2='The site is temporarily unavailable during upgrade process'
    if match "$ERR1\|$ERR2" "$PAGE"; then
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    JS_URL=$(echo "$PAGE" | parse_attr '/timeout\.js' src) || return

    # Wait time after correct captcha
    WAIT_TIME2=$(echo "$PAGE" | parse 'Waiting\.init' "({\([^}]\+\)" | \
        parse_json minLimit) || return
    wait $((WAIT_TIME2)) seconds || return

    # De-obfuscation: timeout.js generates code to be evaled.
    JS_CODE=$(curl -b "$COOKIEFILE" "$JS_URL") || return
    JS_CODE2=$(echo "eval = function(x) { print(x); }; $JS_CODE" | javascript) || return

    # Workaround: SpiderMonkey 1.8 raises an error on anonymous function
    JS_CODE2=$(sed -e 's/^function[[:space:]]*(/1,function(/' <<< "$JS_CODE2")

    PAGE_LINK0=$(echo "
      $JS_CODE2
      clearTimeout = function() { };
      $ = function(x) {
        return {
          trigger: function() { },
          load: function(u) { print('$BASE_URL' + u); }
        };
      };

      Waiting.minLimit = 0;
      Waiting.fileId = '$ID_FILE';
      Waiting.updateTime();
    " | javascript) || return

    # Get the page containing the file url
    PAGE_LINK=$(curl -b "$COOKIEFILE" --referer "$FREE_URL" \
        -H 'X-Requested-With: XMLHttpRequest' "$PAGE_LINK0") || return

    # Sanity check
    if match 'code-404\|text-404' "$PAGE_LINK"; then
        log_error "site updated?"
        return $ERR_FATAL
    fi

    PART_FILE_URL=$(echo "$PAGE_LINK" | parse_attr '/download/redirect' 'href') || return
    FILE_NAME=$(basename_file "$PART_FILE_URL")

    FILE_URL="http://turbobit.net$PART_FILE_URL"
    FILE_URL=$(curl -b "$COOKIEFILE" --include "$FILE_URL" | \
        grep_http_header_location) || return
    FILE_URL=$(curl -b "$COOKIEFILE" --include "$FILE_URL" | \
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
