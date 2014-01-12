#!/bin/bash
#
# mediafire.com module
# Copyright (c) 2011-2013 Plowshare team
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

MODULE_MEDIAFIRE_REGEXP_URL='http://\(www\.\)\?mediafire\.com/'

MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_MEDIAFIRE_DOWNLOAD_RESUME=yes
MODULE_MEDIAFIRE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_MEDIAFIRE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_MEDIAFIRE_UPLOAD_OPTIONS="
ASYNC,,async,,Asynchronous remote upload (only start upload, don't wait for link)
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
FOLDER,,folder,s=FOLDER,Folder to upload files into. Leaf name, no hierarchy.
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
PRIVATE_FILE,,private,,Do not show file in folder view
UNIQUE_FILE,,unique,,Do not allow duplicated filename"

MODULE_MEDIAFIRE_UPLOAD_REMOTE_SUPPORT=yes

MODULE_MEDIAFIRE_LIST_OPTIONS=""
MODULE_MEDIAFIRE_LIST_HAS_SUBFOLDERS=yes

MODULE_MEDIAFIRE_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
mediafire_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local -r ENC_BASE_URL=$(uri_encode_strict <<< "$BASE_URL/")
    local LOGIN_DATA PAGE CODE NAME

    # Make sure we have "ukey" cookie (mandatory)
    curl -c "$COOKIE_FILE" -o /dev/null "$BASE_URL"

    # Notes: - "login_remember=on" not required
    #        - force SSLv3 to avoid problems with curl using OpenSSL/1.0.1
    LOGIN_DATA='login_email=$USER&login_pass=$PASSWORD&submit_login=Login+to+MediaFire'
    PAGE=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
        "${BASE_URL/#http/https}/dynamic/login.php?popup=1" \
        -b "$COOKIE_FILE" --sslv3 --referer "$BASE_URL") || return

    # Note: Cookies "user" and "session" get set on successful login, "skey" is changed"
    CODE=$(echo "$PAGE" | parse 'var et' 'var et= \(-\?[[:digit:]]\+\);') || return
    NAME=$(echo "$PAGE" | parse 'var fp' "var fp='\([^']\+\)';") || return

    # Check for errors
    # Note: All error codes are explained in page returned by server.
    if [ $CODE -ne 15 ]; then
        log_debug "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    log_debug "Successfully logged in as member '$NAME'"
}

# Extract file/folder ID from download link
# $1: Mediafire download URL
# - http://www.mediafire.com/?xyz
# - http://www.mediafire.com/download.php?xyz
# - http://www.mediafire.com/download/xyz/filename...
# $2: probe mode if non empty argument (quiet parsing)
# stdout: file/folder ID
mediafire_extract_id() {
    local -r URL=$1
    local -r PROBE=$2
    local ID

    case "$URL" in
        */download/*)
            ID=$(parse . '/download/\([[:alnum:]]\+\)' <<< "$URL") || return
            ;;

        */folder/*)
            ID=$(parse . '/folder/\([[:alnum:]]\+\)' <<< "$URL") || return
            ;;

        *\?*)
            ID=$(parse . '?\([[:alnum:]]\+\)$' <<< "$URL") || return
            ;;
    esac

    if [ -z "$ID" -a -z "$PROBE" ]; then
        log_error 'Could not parse file/folder ID.'
        return $ERR_FATAL
    fi

    log_debug "File/Folder ID: '$ID'"
    echo "$ID"
}

# Check whether a given ID is a file ID (and not a folder ID)
# $1: Mediafire file/folder ID
# $?: return 0 if ID is a file ID, 1 if it is a folder ID
mediafire_is_file_id() {
    # Folder IDs have 13 digits, file IDs vary in length (11, 15)
    [ ${#1} -ne 13 ]
}

# Retrieve current session key
# $1: cookie file (logged into account)
# $2: base URL
# stdout: session key
mediafire_extract_session_key() {
    local PAGE KEY

    # Though we cannot login via the official API (requires app ID) we can
    # extract the session ID and use most of the API with that :-)
    PAGE=$(curl -b "$1" "$2/myfiles.php") || return
    KEY=$(echo "$PAGE" | \
        parse 'tH.YQ' 'tH.YQ("\([[:xdigit:]]\+\)",') || return

    log_debug "Session key: '$KEY'"
    echo "$KEY"
}

# Check if specified folder name is valid.
# When multiple folders wear the same name, first one is taken.
# $1: session key
# $2: base URL
# $3: (leaf) folder name. No hierarchy.
# stdout: folder key
mediafire_check_folder() {
    local -r SESSION_KEY=$1
    local -r BASE_URL=$2
    local -r NAME=$3
    local -a FOLDER_NAMES # all folder names encountered
    local -a FOLDER_KEYS # all folder keys encountered
    local XML IDX LINE NAMES KEYS

    # Get root folder to initialize folder traversal
    XML=$(curl -d "session_token=$SESSION_KEY" \
        "$BASE_URL/api/folder/get_info.php") || return
    FOLDER_KEYS[0]=$(echo "$XML" | parse_tag . 'folderkey') || return
    FOLDER_NAMES[0]=$(echo "$XML" | parse_tag . 'name') || return
    IDX=0

    while [ $IDX -lt ${#FOLDER_NAMES[@]} ]; do

        # Check whether we found the correct folder
        if [ "${FOLDER_NAMES[$IDX]}" = "$NAME" ]; then
            log_debug "Folder found! Folder key: '${FOLDER_KEYS[$IDX]}'"
            echo "${FOLDER_KEYS[$IDX]}"
            return 0
        fi

        # Get all sub folders
        XML=$(curl -d "session_token=$SESSION_KEY" -d "folder_key=${FOLDER_KEYS[$IDX]}" -d 'content_type=folders' \
            "$BASE_URL/api/folder/get_content.php" | break_html_lines) || return
        KEYS=$(echo "$XML" | parse_all_tag_quiet 'folderkey')
        NAMES=$(echo "$XML" | parse_all_tag_quiet 'name')

        # Append names/keys (if any) to respective array
        if [ -n "$KEYS" ]; then
            while read -r LINE; do
                FOLDER_NAMES[${#FOLDER_NAMES[@]}]=$LINE
            done <<< "$NAMES"

            while read -r LINE; do
                FOLDER_KEYS[${#FOLDER_KEYS[@]}]=$LINE
            done <<< "$KEYS"
        fi

        (( ++IDX ))
    done

    log_error 'Invalid folder, choose from:' ${FOLDER_NAMES[*]}
    return $ERR_BAD_COMMAND_LINE
}

mediafire_get_ofuscated_link() {
    local VAR=$1
    local I N C R

    I=0
    N=${#VAR}
    while (( I < N )); do
        C=$((16#${VAR:$I:2} + 0x18))
        R="$R"$(printf \\$(($C/64*100+$C%64/8*10+$C%8)))
        (( I += 2 ))
    done
    echo "$R"
}

# Output a mediafire file download URL
# $1: cookie file
# $2: mediafire.com url
# stdout: real file download link
mediafire_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://www.mediafire.com'
    local FILE_ID URL PAGE JSON JS_VAR

    if [ -n "$AUTH_FREE" ]; then
        mediafire_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    FILE_ID=$(mediafire_extract_id "$2") || return

    if ! mediafire_is_file_id "$FILE_ID"; then
        log_error 'This is a folder link. Please use plowlist!'
        return $ERR_FATAL
    fi

    # Only get site headers first to capture direct download links
    URL=$(curl --head "$BASE_URL/?$FILE_ID" | grep_http_header_location_quiet) || return

    case "$URL" in
        # no redirect, normal download
        '')
            URL="$BASE_URL/?$FILE_ID"
            ;;
        /download/*)
            URL="$BASE_URL$URL"
            ;;
        http://*)
            log_debug 'Direct download'
            echo "$URL"
            return 0
            ;;
        *errno=999)
            return $ERR_LINK_NEED_PERMISSIONS
            ;;
        *errno=320|*errno=378)
            return $ERR_LINK_DEAD
            ;;
        *errno=*)
            log_error "Unexpected remote error: ${URL#*errno=}"
            return $ERR_FATAL
    esac

    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL" | break_html_lines) || return

    # <h3 class="error_msg_title">Invalid or Deleted File.</h3>
    match 'Invalid or Deleted File' "$PAGE" && return $ERR_LINK_DEAD

    # handle captcha (reCaptcha or SolveMedia) if there is one
    if match '<form[^>]*form_captcha' "$PAGE"; then
        local FORM_CAPTCHA PUBKEY CHALLENGE ID RESP CAPTCHA_DATA

        FORM_CAPTCHA=$(grep_form_by_name "$PAGE" 'form_captcha') || return

        if match 'recaptcha/api' "$FORM_CAPTCHA"; then
            log_debug 'reCaptcha found'

            local WORD
            PUBKEY='6LextQUAAAAAALlQv0DSHOYxqF3DftRZxA5yebEe'
            RESP=$(recaptcha_process $PUBKEY) || return
            { read WORD; read CHALLENGE; read ID; } <<< "$RESP"

            CAPTCHA_DATA="-d recaptcha_challenge_field=$CHALLENGE -d recaptcha_response_field=$WORD"

        elif match 'api\.solvemedia' "$FORM_CAPTCHA"; then
            log_debug 'Solve Media CAPTCHA found'

            PUBKEY='Z94dMnWequbvKmy-HchLrZJ3-.qB6AJ1'
            RESP=$(solvemedia_captcha_process $PUBKEY) || return
            { read CHALLENGE; read ID; } <<< "$RESP"

            CAPTCHA_DATA="--data-urlencode adcopy_challenge=$CHALLENGE -d adcopy_response=manual_challenge"

        else
            log_error 'Unexpected content/captcha type. Site updated?'
            return $ERR_FATAL
        fi

        log_debug "Captcha data: $CAPTCHA_DATA"

        PAGE=$(curl --location -b "$COOKIE_FILE" --referer "$URL" \
            $CAPTCHA_DATA "$BASE_URL/?$FILE_ID") || return

        # Your entry was incorrect, please try again!
        if match 'Your entry was incorrect' "$PAGE"; then
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug 'Correct captcha'
    fi

    # Check for password protected link
    if match 'name="downloadp"' "$PAGE"; then
        log_debug 'File is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi
        PAGE=$(curl -L --post301 -b "$COOKIE_FILE" \
            -d "downloadp=$LINK_PASSWORD" "$URL" | break_html_lines) || return

        match 'name="downloadp"' "$PAGE" && return $ERR_LINK_PASSWORD_REQUIRED
    fi

    JS_VAR=$(echo "$PAGE" | parse 'function[[:space:]]*_' '"\([^"]\+\)";' 1) || return

    # extract + output download link + file name
    mediafire_get_ofuscated_link "$JS_VAR" | parse_attr href || return
    if ! parse_attr 'og:title' 'content' <<< "$PAGE"; then
        parse_tag 'title' <<< "$PAGE" || return
    fi
}

# Static function. Proceed with login using official API
# $1: authentication
# $2: base url
# stdout: account type ("free" or "premium") on success
mediafire_api_get_session_token() {
    local -r AUTH=$1
    local -r BASE_URL=$2
    local EMAIL PASSWORD HASH JSON RES ERR

    # Plowshare App ID & API key
    local -r APP_ID=36434
    local -r KEY='mqio689reumyxs7p2xjd18asj388lle2h6hpx6m5'

    split_auth "$AUTH" EMAIL PASSWORD || return
    HASH=$(sha1 "$EMAIL$PASSWORD$APP_ID$KEY") || return

    JSON=$(curl -d "email=$EMAIL" \
        -d "password=$(echo "$PASSWORD" | uri_encode_strict)" \
        -d "application_id=$APP_ID" \
        -d "signature=$HASH" \
        -d 'version=1' -d 'response_format=json' \
        "$BASE_URL/api/user/get_session_token.php") || return

    RES=$(echo "$JSON" | parse_json 'result' 'split') || return

    if [ "$RES" != 'Success' ]; then
        ERR=$(echo "$JSON" | parse_json 'error' 'split') || return
        log_error "Remote error: '$ERR'"
        return $ERR_LOGIN_FAILED
    fi

    echo "$JSON" | parse_json 'session_token' 'split' || return
}

# Upload a file to mediafire using official API.
# https://www.mediafire.com/developers/upload.php
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: mediafire.com download link
mediafire_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='https://www.mediafire.com'
    local SESSION_TOKEN JSON RES KEY_ID UPLOAD_KEY QUICK_KEY FOLDER_KEY

    # Sanity checks
    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS

    if [ -n "$ASYNC" ] && ! match_remote_url "$FILE"; then
        log_error 'Cannot upload local files asynchronously.'
        return $ERR_BAD_COMMAND_LINE
    fi

    if [ -n "$ASYNC" -a \( -n "$DESCRIPTION" -o -n "$LINK_PASSWORD" -o \
        -n "$PRIVATE_FILE" \) ] ; then
        log_error 'Advanced options not available for asynchronously uploaded files.'
        return $ERR_BAD_COMMAND_LINE
    fi

    # FIXME
    if [ -z "$ASYNC" ] && match_remote_url "$FILE"; then
        log_error 'Synchronous remote upload not implemented.'
        return $ERR_BAD_COMMAND_LINE
    fi

    SESSION_TOKEN=$(mediafire_api_get_session_token "$AUTH_FREE" "$BASE_URL") || return
    log_debug "Session Token: '$SESSION_TOKEN'"

    # API bug
    if [ "${#DEST_FILE}" -lt 3 ]; then
        log_error 'Filenames less than 3 characters cannot be uploaded. Mediafire API bug? This is not a plowshare bug!'
    fi

    if [ -n "$FOLDER" ]; then
        FOLDER_KEY=$(mediafire_check_folder "$SESSION_TOKEN" "$BASE_URL" "$FOLDER") || return
    fi

    # Check for duplicate name
    JSON=$(curl --get -d "session_token=$SESSION_TOKEN" -d "filename=$DEST_FILE" \
        -d 'response_format=json' \
        -d 'action_on_duplicate=keep' \
         ${FOLDER:+-d "upload_folder_key=$FOLDER_KEY"} \
        "$BASE_URL/api/upload/pre_upload.php") || return

    RES=$(parse_json result <<<"$JSON") || return
    if [ "$RES" != 'Success' ]; then
        local NUM MSG
        NUM=$(parse_json_quiet error <<<"$JSON")
        MSG=$(parse_json_quiet message <<<"$JSON")
        log_error "Unexpected remote error (pre_upload): $NUM, '$MSG'"
        return $ERR_FATAL
    fi

    # "duplicate_name":"yes","duplicate_quickkey":"2xrys3f97a9t9ce"
    # Note: "duplicate_name" is not always returned ???
    QUICK_KEY=$(parse_json_quiet 'duplicate_quickkey' <<<"$JSON") || return
    if [ -n "$QUICK_KEY" ]; then
        if [ -n "$UNIQUE_FILE" ]; then
            log_error 'Duplicated filename. Return original quickkey.'
            echo "$BASE_URL/?$QUICK_KEY"
            return 0
        else
            log_debug 'a file with the same filename already exists. File will be renamed.'
        fi
    fi

    # "used_storage_size":"10438024","storage_limit":"53687091200","storage_limit_exceeded":"no"
    RES=$(parse_json storage_limit_exceeded <<<"$JSON") || return
    if [ "$RES" = 'yes' ]; then
       log_error 'Storage limit exceeded. Abort.'
       return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Start upload
    if match_remote_url "$FILE"; then
        JSON=$(curl -d "session_token=$SESSION_TOKEN" \
            -d "filename=$DESTFILE"                   \
            -d 'response_format=json'                 \
            --data-urlencode "url=$FILE"              \
            ${FOLDER:+"-d folder_key=$FOLDER_KEY"}    \
            "$BASE_URL/api/upload/add_web_upload.php") || return

        KEY_ID='upload_key'
    else
        local FILE_SIZE
        FILE_SIZE=$(get_filesize "$FILE") || return

        JSON=$(curl_with_log -F "Filedata=@$FILE;filename=$DESTFILE" \
            --header "x-filename: $DEST_FILE" \
            --header "x-size: $FILE_SIZE" \
            "$BASE_URL/api/upload/upload.php?session_token=$SESSION_TOKEN&action_on_duplicate=keep&response_format=json${FOLDER:+"&uploadkey=$FOLDER_KEY"}") || return

        KEY_ID='key'
    fi

    # Check for errors
    RES=$(parse_json result <<<"$JSON") || return
    if [ "$RES" != 'Success' ]; then
        local NUM MSG
        NUM=$(parse_json_quiet error <<<"$JSON")
        MSG=$(parse_json_quiet message <<<"$JSON")
        log_error "Unexpected remote error (upload): $NUM, '$MSG'"
        return $ERR_FATAL
    fi

    UPLOAD_KEY=$(parse_json "$KEY_ID" <<< "$JSON") || return
    log_debug "polling for status update (with key $UPLOAD_KEY)"
    QUICK_KEY=''

    # Wait for upload to finish
    if match_remote_url "$FILE"; then
        [ -n "$ASYNC" ] && return $ERR_ASYNC_REQUEST
    else
        for N in 3 3 2 2 2; do
            wait $N seconds || return

            JSON=$(curl --get -d "session_token=$SESSION_TOKEN" \
                -d 'response_format=json' -d "key=$UPLOAD_KEY"  \
                "$BASE_URL/api/upload/poll_upload.php") || return

            RES=$(parse_json result <<<"$JSON") || return
            if [ "$RES" != 'Success' ]; then
                log_error "FIXME '$JSON'"
                return $ERR_FATAL
            fi

            # No more requests for this key
            RES=$(parse_json status <<<"$JSON") || return
            if [ "$RES" = '99' ]; then
                QUICK_KEY=$(parse_json quickkey <<<"$JSON") || return
                break
            fi
        done
    fi

    if [ -z "$QUICK_KEY" ]; then
        local MSG ERR
        MSG=$(parse_json_quiet description <<<"$JSON")
        ERR=$(parse_json_quiet fileerror <<<"$JSON")
        log_error "Bad status $RES: '$MSG'"
        log_debug "fileerror: '$ERR'"
        return $ERR_FATAL
    fi

    if [ -n "$DESCRIPTION" -o -n "$PRIVATE_FILE" ]; then
        JSON=$(curl -d "session_token=$SESSION_TOKEN" \
            -d "quick_key=$QUICK_KEY" -d 'response_format=json' \
            ${DESCRIPTION:+-d "description=$DESCRIPTION"} \
            ${PRIVATE_FILE:+-d 'privacy=private'} \
            "$BASE_URL/api/file/update.php") || return

        RES=$(parse_json result <<<"$JSON")
        if [ "$RES" != 'Success' ]; then
            log_error 'Could not set description/hide file.'
        fi
    fi

    # Note: Making a file private removes its password...
    if [ -n "$LINK_PASSWORD" ]; then
        JSON=$(curl -d "session_token=$SESSION_TOKEN" \
            -d "quick_key=$QUICK_KEY" -d 'response_format=json' \
            -d "password=$LINK_PASSWORD" \
            "$BASE_URL/api/file/update_password.php") || return

        RES=$(parse_json result <<<"$JSON")
        if [ "$RES" != 'Success' ]; then
            log_error 'Could not set password.'
        fi
    fi

    echo "$BASE_URL/?$QUICK_KEY"
}

# List a mediafire shared file folder URL
# $1: mediafire folder url (http://www.mediafire.com/?sharekey=...)
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
mediafire_list() {
    local URL=$1
    local REC=$2
    local -r BASE_URL='http://www.mediafire.com'
    local -r CHUNK_SIZE=100 # default chunk size
    local RET=$ERR_LINK_DEAD
    local XML FOLDER_KEY ERR NUM_FILES NUM_FOLDERS NUM_CHUNKS CHUNK NAMES LINKS

    if [[ $URL = */?sharekey=* ]]; then
        local LOCATION

        LOCATION=$(curl --head "$URL" | grep_http_header_location) || return
        if [[ "$LOCATION" != /* ]]; then
            log_error 'This is not a shared folder'
            return $ERR_FATAL
        fi
        FOLDER_KEY=$(mediafire_extract_id "$LOCATION") || return
    else
        FOLDER_KEY=$(mediafire_extract_id "$URL" 1)

        # http://www.mediafire.com/username
        if [ -z "$FOLDER_KEY" ]; then
            #local PAGE
            #PAGE=$(curl -L "$URL") || return

            # FIXME: obfuscated js..
            log_error 'Sorry, this folder url is not handled yet'
            return $ERR_FATAL
        fi
    fi

    if mediafire_is_file_id "$FOLDER_KEY"; then
        log_error 'This is a file link. Please use plowdown!'
        return $ERR_FATAL
    fi

    XML=$(curl -d "folder_key=$FOLDER_KEY" \
        "$BASE_URL/api/folder/get_info.php") || return

    # Check for errors
    ERR=$(echo "$XML" | parse_tag_quiet 'message')

    if [ -n "$ERR" ]; then
        log_error "Remote error: $ERR"
        return $ERR_FATAL
    fi

    # Note: This numbers also includes private files!
    NUM_FILES=$(echo "$XML" | parse_tag 'file_count') || return
    NUM_FOLDERS=$(echo "$XML" | parse_tag 'folder_count') || return
    log_debug "There is/are $NUM_FILES file(s) and $NUM_FOLDERS sub folder(s)"

    # Handle files (NUM_CHUNKS = ceil(NUM_FILES / CHUNK_SIZE))
    NUM_CHUNKS=$(( (NUM_FILES + CHUNK_SIZE - 1) / CHUNK_SIZE ));
    CHUNK=0

    while (( ++CHUNK <= NUM_CHUNKS )); do
        XML=$(curl -d "folder_key=$FOLDER_KEY" -d 'content_type=files' \
            -d "chunk=$CHUNK" "$BASE_URL/api/folder/get_content.php"   \
            | break_html_lines) || return

        NAMES=$(echo "$XML" | parse_all_tag_quiet 'filename')
        LINKS=$(echo "$XML" | parse_all_tag_quiet 'quickkey')

        list_submit "$LINKS" "$NAMES" "$BASE_URL/?" && RET=0
    done

    # Handle folders
    if [ -n "$REC" ]; then
        local LINK

        NUM_CHUNKS=$(( (NUM_FOLDERS + CHUNK_SIZE - 1) / CHUNK_SIZE ));
        CHUNK=0

        while (( ++CHUNK <= NUM_CHUNKS )); do
            XML=$(curl -d "folder_key=$FOLDER_KEY" -d 'content_type=folders' \
                -d "chunk=$CHUNK" "$BASE_URL/api/folder/get_content.php"     \
                | break_html_lines) || return

            LINKS=$(echo "$XML" | parse_all_tag 'folderkey') || return

            for LINK in $LINKS; do
                log_debug "Entering sub folder: $LINK"
                mediafire_list "$BASE_URL/?$LINK" "$REC" && RET=0
            done
        done
    fi

    return $RET
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: Mediafire url
# $3: requested capability list
# stdout: 1 capability per line
mediafire_probe() {
    local -r REQ_IN=$3
    local -r BASE_URL='http://www.mediafire.com'
    local FILE_ID XML REQ_OUT

    FILE_ID=$(mediafire_extract_id "$2") || return

    if ! mediafire_is_file_id "$FILE_ID"; then
        log_error 'This is a folder link. Please use plowlist!'
        return $ERR_FATAL
    fi

    XML=$(curl -d "quick_key=$FILE_ID" "$BASE_URL/api/file/get_info.php") || return

    if [[ "$XML" = *\<error\>* ]]; then
        local ERR MESSAGE
        ERR=$(echo "$XML" | parse_tag_quiet 'error')

        [ "$ERR" -eq 110 ] && return $ERR_LINK_DEAD

        MESSAGE=$(echo "$XML" | parse_tag_quiet 'message')
        log_error "Unexpected remote error: $MESSAGE ($ERR)"
        return $ERR_FATAL
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$XML" | parse_tag 'filename' && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        echo "$XML" | parse_tag 'size' && REQ_OUT="${REQ_OUT}s"
    fi

    # also available: file description, tags, public/private,
    # password protection, filetype, mimetype, file owner, date of creation

    echo $REQ_OUT
}
