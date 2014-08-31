# Plowshare turbobit.net module
# Copyright (c) 2012-2014 Plowshare team
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

MODULE_TURBOBIT_REGEXP_URL='http://\(www\.\)\?turbobit\.net/'

MODULE_TURBOBIT_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_TURBOBIT_DOWNLOAD_RESUME=yes
MODULE_TURBOBIT_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_TURBOBIT_DOWNLOAD_SUCCESSIVE_INTERVAL=600

MODULE_TURBOBIT_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_TURBOBIT_UPLOAD_REMOTE_SUPPORT=no

MODULE_TURBOBIT_LIST_OPTIONS=""
MODULE_TURBOBIT_LIST_HAS_SUBFOLDERS=no

MODULE_TURBOBIT_DELETE_OPTIONS=""
MODULE_TURBOBIT_PROBE_OPTIONS=""

# Static function. Proceed with login (free or premium)
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
turbobit_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL="$3/user/login"
    local LOGIN_DATA PAGE STATUS EMAIL TYPE

    # Force page in English
    LOGIN_DATA='user[login]=$USER&user[pass]=$PASSWORD&user[submit]=Login&user[memory]=on'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL" -b 'user_lang=en' --location) || return

    # <div class='error'>Limit of login attempts exeeded.</div>
    if match '>Limit of login attempts exeeded\.<' "$PAGE"; then
        if match 'onclick="updateCaptchaImage()"' "$PAGE"; then
            local CAPTCHA_URL CAPTCHA_TYPE CAPTCHA_SUBTYPE CAPTCHA_IMG

            CAPTCHA_URL=$(echo "$PAGE" | parse_attr 'alt="Captcha"' 'src') || return
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

            # Mandatory: -b "$COOKIE_FILE"
            LOGIN_DATA="$LOGIN_DATA&user[captcha_response]=$WORD&user[captcha_type]=$CAPTCHA_TYPE&user[captcha_subtype]=$CAPTCHA_SUBTYPE"
            PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
                "$BASE_URL" -b "$COOKIE_FILE" -b 'user_lang=en' --location) || return

            # <div class='error'>Incorrect verification code</div>
            if match 'Incorrect verification code' "$PAGE"; then
                captcha_nack $ID
                log_error 'Wrong captcha'
                return $ERR_CAPTCHA
            fi

            captcha_ack $ID
            log_debug 'Correct captcha'
        else
            log_error 'Too many logins, must wait'
            return $ERR_FATAL
        fi
    fi

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

# Static function. Check query answer
# $1: JSON data (like {"status":"xxx","error":{"code":x,"msg":"xxx"}, ...}
# $?: 0 for success
turbobit_api_status() {
    local STATUS=$(parse_json 'status' <<< "$1")
    if [ "$STATUS" != 'success' ]; then
        local MSG=$(parse_json 'msg' <<< "$1")
        log_error "Remote status: '$STATUS'"
        [ -z "$MSG" ] || log_error "Message: $MSG"
        return $ERR_FATAL
    fi
}

# Static function. Proceed with login (free or premium)
# $1: authentication
# $2: base url
# stdout: userid:usertoken (single line) on success
turbobit_api_login() {
    local -r AUTH=$1
    local -r BASE_URL="$2/login"
    local JSON USER PASSWORD USER_ID USER_TOKEN

    split_auth "$1" USER PASSWORD || return
    JSON=$(curl --data "login=$USER&password=$PASSWORD" \
        "$BASE_URL") || return

    turbobit_api_status "$JSON" || return $ERR_LOGIN_FAILED

    USER_ID=$(parse_json 'user_id' <<< "$JSON") || return
    USER_TOKEN=$(parse_json 'token' <<< "$JSON") || return

    log_debug "Successfully logged in as member '$USER'"
    echo "$USER_ID:$USER_TOKEN"
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

    # This document was not found in System
    # File was not found. It could possibly be deleted.
    # File not found. Probably it was deleted.
    matchi '\(file\|document\)\( was\)\? not found' "$PAGE" && return $ERR_LINK_DEAD

    # Download xyz. Free download without registration from TurboBit.net
    FILE_NAME=$(echo "$PAGE" | parse '<title>' \
        '^[[:blank:]]*Download \(.\+\). Free' 1) || return

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(turbobit_login "$AUTH" "$COOKIE_FILE" \
            "$BASE_URL") || return

        if [ "$ACCOUNT" = 'premium' ]; then
            MODULE_TURBOBIT_DOWNLOAD_SUCCESSIVE_INTERVAL=0 # guessing for now

            PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return
            FILE_URL=$(echo "$PAGE" | parse_attr '/redirect/' 'href') || return

            # Redirects 2 times...
            FILE_URL=$(curl -b "$COOKIE_FILE" --head "$FILE_URL" | \
                grep_http_header_location) || return
            FILE_URL=$(curl -b "$COOKIE_FILE" --head "$FILE_URL" | \
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
        "$BASE_URL$PAGE_LINK") || return

    # Sanity check
    if match 'code-404\|text-404' "$PAGE"; then
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr '/download/redirect/' 'href') || return
    FILE_URL="$BASE_URL$FILE_URL"

    # Redirects 2 times...
    FILE_URL=$(curl -b "$COOKIE_FILE" --head "$FILE_URL" | \
        grep_http_header_location) || return
    FILE_URL=$(curl -b "$COOKIE_FILE" --head "$FILE_URL" | \
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
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://api.turbobit.net/v001/ftn'
    local JSON LOGINDATA POSTDATA FILE_SIZE FILE_NAME
    local UP_URL FILE_ID FILE_LINK DELETE_LINK

    FILE_SIZE=$(get_filesize "$FILE") || return
    FILE_NAME=$(echo "$DEST_FILE" | uri_encode_strict)
    POSTDATA="user_file_name=$FILE_NAME&size=$FILE_SIZE"

    if [ -n "$AUTH" ]; then
        LOGINDATA=$(turbobit_api_login "$AUTH" "$BASE_URL") || return
        POSTDATA="$POSTDATA&user_id=${LOGINDATA%%:*}&token=${LOGINDATA#*:}"
    fi

    JSON=$(curl --data "$POSTDATA" "$BASE_URL/getUploadUrl") || return
    turbobit_api_status "$JSON" || return

    UP_URL=$(parse_json 'upload_link' <<< "$JSON") || return

    log_debug "Upload host: '$(basename_url "$UP_URL")'"

    JSON=$(curl_with_log --request POST \
        --header 'Content-Type: application/octet-stream' \
        --header "Content-Disposition: attachment; filename=\"$DEST_FILE\"" \
        --upload-file "$FILE" \
        "$UP_URL") || return

    turbobit_api_status "$JSON" || return

    FILE_ID=$(parse_json 'file_id' <<< "$JSON") || return
    log_debug "File ID: $FILE_ID"

    FILE_LINK=$(parse_json 'download_link' <<< "$JSON") || return
    DELETE_LINK=$(parse_json 'delete_link' <<< "$JSON") || return

    echo "$FILE_LINK"
    echo "${DELETE_LINK/v001\/ftn\/deleteFile/delete\/file}"
}

# Delete a file on turbobit
# $1: cookie file (unused here)
# $2: delete link
turbobit_delete() {
    local PAGE URL

    PAGE=$(curl -b 'user_lang=en' "$2") || return

    # You can't remove this file - code is incorrect
    if match 'code is incorrect' "$PAGE"; then
        log_error 'bad deletion code'
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

# List a turbobit.net folder
# $1: turbobit.net folder link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
turbobit_list() {
    local -r URL=$1
    local PAGE QUERY_URL FOLDER_ID JSON LINKS NAMES

    if ! match '/folder/' "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    PAGE=$(curl -L -b 'user_lang=en' "$URL") || return

    QUERY_URL=$(echo "$PAGE" | parse '[[:space:]]url:' "'\(/[^']*\)")
    FOLDER_ID=$(echo "$PAGE" | parse '[[:space:]]postData:' \
      'id_folder:[[:space:]]\([[:digit:]]\+\)') || return

    JSON=$(curl --get  -b 'user_lang=en' \
        -d "id_folder=$FOLDER_ID" -d 'rows=400' \
        "http://turbobit.net$QUERY_URL") || return

    LINKS=$(parse_json 'id' 'split' <<<"$JSON")

    # Not very classy! sed makes one link per line.
    NAMES=$(parse_all . '_blank.>\([^<]*\)<\\/a>",' <\
        <(sed -e 's/]/]\n/g' <<<"$JSON"))

    test "$LINKS" || return $ERR_LINK_DEAD

    list_submit "$LINKS" "$NAMES" 'http://turbobit.net/' '.html' || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: Turbobit url
# $3: requested capability list
# stdout: 1 capability per line
turbobit_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -b 'user_lang=en' "$URL") || return

    # This document was not found in System
    # File was not found. It could possibly be deleted.
    # File not found. Probably it was deleted.
    matchi '\(file\|document\)\( was\)\? not found' "$PAGE" && return $ERR_LINK_DEAD
    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$PAGE" | parse '<title>' \
            '^[[:blank:]]*Download \(.\+\). Free' 1 && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        # Note: Site uses 'b' for byte but 'translate_size' wants 'B'
        FILE_SIZE=$(echo "$PAGE" | parse 'Download file:'  \
            '(\([[:digit:]]\+\(,[[:digit:]]\+\)\?[[:space:]][KMG]\?b\)\(yte\)\?)$' 1) &&
            translate_size "${FILE_SIZE%b}B" && REQ_OUT="${REQ_OUT}s"
    fi

    # File hash is only available as part of the download link :-/
    echo $REQ_OUT
}
