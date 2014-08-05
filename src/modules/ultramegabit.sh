# Plowshare ultramegabit.com module
# Copyright (c) 2013 Plowshare team
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

MODULE_ULTRAMEGABIT_REGEXP_URL='https\?://\(www\.\)\?ultramegabit\.com/file/details/'

MODULE_ULTRAMEGABIT_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_ULTRAMEGABIT_DOWNLOAD_RESUME=yes
MODULE_ULTRAMEGABIT_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_ULTRAMEGABIT_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_ULTRAMEGABIT_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
FOLDER,,folder,s=FOLDER,Folder to upload files into"
MODULE_ULTRAMEGABIT_UPLOAD_REMOTE_SUPPORT=yes

MODULE_ULTRAMEGABIT_PROBE_OPTIONS=""

# Static function. Proceed with login.
ultramegabit_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local PAGE LOGIN_DATA LOGIN_RESULT LOCATION CSRF_TOKEN

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        "$BASE_URL/login") || return

    CSRF_TOKEN=$(parse_form_input_by_name 'csrf_token' <<< "$PAGE") || return

    LOGIN_DATA="csrf_token=$CSRF_TOKEN&username=\$USER&password=\$PASSWORD"
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login" \
        -b "$COOKIE_FILE" -e "$BASE_URL/login" -i) || return

    LOCATION=$(grep_http_header_location_quiet <<< "$LOGIN_RESULT")

    if ! match 'http://ultramegabit.com/home' "$LOCATION"; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a ultramegabit.com file download URL and name
# $1: cookie file
# $2: ultramegabit.com url
# stdout: file download link
#         file name
ultramegabit_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2

    local PAGE FILE_URL FILE_NAME WAIT_TIME TIME LOCATION
    local FORM_HTML FORM_ACTION FORM_CSRF_TOKEN FORM_ENCODE FORM_CAPTCHA

    if [ -n "$AUTH" ]; then
        ultramegabit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return
    FILE_NAME=$(parse '<h4><img' ' /> \(.*\) ([0-9\.]\+ [A-Z]\{2\})</h4>' <<< "$PAGE") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")
    if match 'http://ultramegabit.com/folder/add' "$LOCATION" ||
        match 'File has been deleted' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    if match 'Premium only download' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    WAIT_TIME=$(parse_all 'dts = ' '(1 \* \([0-9]\+\)' <<< "$PAGE" | last_line) || return

    # If password or captcha is too long
    [ -n "$WAIT_TIME" ] && TIME=$(date +%s)

    if match 'recaptcha.*?k=' "$PAGE"; then
        local PUBKEY WCI CHALLENGE WORD ID
        # http://www.google.com/recaptcha/api/challenge?k=
        PUBKEY=$(parse 'recaptcha.*?k=' '?k=\([[:alnum:]_-.]\+\)' <<< "$PAGE") || return
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        FORM_CAPTCHA="-d recaptcha_challenge_field=$CHALLENGE -d recaptcha_response_field=$WORD"
    fi

    if [ -n "$WAIT_TIME" ]; then
        TIME=$(($(date +%s) - $TIME))
        if [ $TIME -lt $WAIT_TIME ]; then
            WAIT_TIME=$((WAIT_TIME - $TIME))
            wait $WAIT_TIME || return
        fi
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_CSRF_TOKEN=$(parse_form_input_by_name 'csrf_token' <<< "$FORM_HTML") || return
    FORM_ENCODE=$(parse_form_input_by_name 'encode' <<< "$FORM_HTML") || return

    PAGE=$(curl -i -e "$URL" -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -d "csrf_token=$FORM_CSRF_TOKEN" \
        -d "encode=$FORM_ENCODE" \
        $FORM_CAPTCHA \
        "$FORM_ACTION") || return

    if match 'The ReCAPTCHA field is required' "$PAGE"; then
        log_error 'Wrong captcha.'
        captcha_nack $ID
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID

    FILE_URL=$(grep_http_header_location <<< "$PAGE") || return

    if match 'delay' "$FILE_URL"; then
        PAGE=$(curl -b "$COOKIE_FILE" "$FILE_URL") || return

        WAIT_TIME=$(parse '^[[:space:]]*ts' '^[[:space:]]*ts = (\(.*\)) \* 1000' <<< "$PAGE") || return
        TIME=$(date +%s)
        log_error 'Forced delay between downloads.'

        echo $(( WAIT_TIME - TIME ))
        return $ERR_LINK_TEMP_UNAVAILABLE

    # File size restriction
    elif match 'alert/size' "$FILE_URL"; then
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Check if specified folder name is valid.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base url
# stdout: folder ID
ultramegabit_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local PAGE LOCATION FOLDER_ID CSRF_TOKEN FOLDERS

    log_debug 'Getting folder data'

    PAGE=$(curl -L -b "$COOKIE_FILE" "$BASE_URL/home") || return

    CSRF_TOKEN=$(parse_form_input_by_name 'csrf_token' <<< "$PAGE") || return
    FOLDERS=$(parse_all 'move_destination' '</span> &nbsp; \(.*\) <span' <<< "$PAGE") || return

    # Create folder if not exist
    if ! match "^$NAME$" "$FOLDERS"; then
        log_debug "Creating folder: '$NAME'"

        PAGE=$(curl -b "$COOKIE_FILE" -i \
            -d "csrf_token=$CSRF_TOKEN" \
            -d "parent_id=" \
            -d "name=$NAME" \
            "$BASE_URL/folder/create") || return

        LOCATION=$(grep_http_header_location <<< "$PAGE") || return

        if ! match '^http://ultramegabit.com/folder/add/' "$LOCATION"; then
            log_error 'Failed to create folder.'
            return $ERR_FATAL
        fi

        FOLDER_ID=$(parse . '^http://ultramegabit.com/folder/add/\(.*\)$' <<< "$LOCATION")
    else
        FOLDER_ID=$(parse "move_destination.*</span> &nbsp; $NAME <span" ' id="\([^"]\+\)' <<< "$PAGE") || return
    fi

    log_debug "Folder ID: '$FOLDER_ID'"
    echo "$FOLDER_ID"
}

# Upload a file to ultramegabit.com
# $1: cookie file
# $2: file path or remote url
# $3: remote filename
# stdout: download link
ultramegabit_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r MAX_SIZE=1073741824 # 1024 MiB
    local -r BASE_URL='http://ultramegabit.com'
    local PAGE FOLDER_ID UP_BASE_URL
    local FORM_HTML FORM_CSRF_TOKEN FORM_FOLDER_ID FORM_USER_ID FORM_FOLDER_ID

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    if [ -n "$FOLDER" ]; then
        if ! match '^[[:alnum:] ]\+$' "$FOLDER"; then
            log_error 'Folder must be alphanumeric.'
            return $ERR_FATAL
        fi
    fi

    if ! match_remote_url "$FILE"; then
        local SZ=$(get_filesize "$FILE")
        if [ "$SZ" -gt "$MAX_SIZE" ]; then
            log_debug "File is bigger than $MAX_SIZE."
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    if [ -n "$AUTH" ]; then
        ultramegabit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(ultramegabit_check_folder "$FOLDER" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    PAGE=$(curl -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        "$BASE_URL/home") || return

    UP_BASE_URL=$(parse 'url.*web/add' "url: '\([^']\+\)" <<< "$PAGE") || return
    UP_BASE_URL=$(basename_url "$UP_BASE_URL")

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_CSRF_TOKEN=$(parse_form_input_by_name 'csrf_token' <<< "$FORM_HTML") || return
    FORM_FOLDER_ID=$(parse_form_input_by_name 'folder_id' <<< "$FORM_HTML") || return
    FORM_USER_ID=$(parse_form_input_by_name 'user_id' <<< "$FORM_HTML") || return

    if [ -n "$FOLDER" ]; then
        FORM_FOLDER_ID="$FOLDER_ID"
    fi

    # Upload remote file
    if match_remote_url "$FILE"; then
        local LAST_FILE_ID FILE_ID

        if ! match '^https\?://' "$FILE" && ! match '^ftp://' "$FILE"; then
            log_error 'Unsupported protocol for remote upload.'
            return $ERR_BAD_COMMAND_LINE
        fi

        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            "$BASE_URL/folder/get_files/$FORM_FOLDER_ID/date") || return

        LAST_FILE_ID=$(parse_quiet '^\[{"id":"' '^\[{"id":"\([^"]\+\)' <<< "$PAGE")

        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
                -F 'remote_login=' \
                -F 'remote_password=' \
                -F "folder_id=$FORM_FOLDER_ID" \
                -F "user_id=$FORM_USER_ID" \
                -F "urls=$FILE" \
                "$UP_BASE_URL/remote/add") || return

        if ! match '[info_hash]' "$PAGE" && ! match 'its a dupe' "$PAGE"; then
            log_error 'Remote upload failed.'
            return $ERR_FATAL
        fi

        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            "$BASE_URL/folder/get_files/$FORM_FOLDER_ID/date") || return

        FILE_ID=$(parse_quiet '^\[{"id":"' '^\[{"id":"\([^"]\+\)' <<< "$PAGE")

        if [ "$FILE_ID" = "$LAST_FILE_ID" ]; then
            log_debug 'Remote upload failed.'
            return $ERR_FATAL
        fi

        # Do we need to rename the file?
        if [ "$DEST_FILE" != 'dummy' ]; then
            log_debug 'Renaming file'

            PAGE=$(curl -b "$COOKIE_FILE" \
                "$BASE_URL/file/edit/$FILE_ID") || return

            FORM_CSRF_TOKEN=$(parse_form_input_by_name 'csrf_token' <<< "$PAGE") || return

            PAGE=$(curl -b "$COOKIE_FILE" -i \
                -d "csrf_token=$FORM_CSRF_TOKEN" \
                -d "folder=$FORM_FOLDER_ID" \
                -d "name=$DEST_FILE" \
                "$BASE_URL/file/edit/$FILE_ID") || return

            LOCATION=$(grep_http_header_location <<< "$PAGE") || return

            if ! match '^http://ultramegabit.com/home$' "$LOCATION"; then
                log_error 'Failed to rename file.'
                #return $ERR_FATAL
            fi
        fi

        LINK_DL="http://ultramegabit.com/file/details/$FILE_ID"

    # Upload local file
    else
        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
                -F "csrf_token=$FORM_CSRF_TOKEN" \
                -F "folder_id=$FORM_FOLDER_ID" \
                -F "user_id=$FORM_USER_ID" \
                -F "file=@$FILE;filename=$DESTFILE" \
                "$UP_BASE_URL/web/add") || return

        LINK_DL=$(parse_json 'url' <<< "$PAGE") || return
    fi

    echo "$LINK_DL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: ultramegabit.com url
# $3: requested capability list
# stdout: 1 capability per line
ultramegabit_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE LOCATION FILE_NAME FILE_SIZE REQ_OUT

    PAGE=$(curl -i "$URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")
    if match 'http://ultramegabit.com/folder/add' "$LOCATION" ||
        match 'File has been deleted' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '<h4><img' ' /> \(.*\) ([0-9\.]\+ [A-Z]\{2\})</h4>' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '<h4><img' '(\([0-9\.]\+ [A-Z]\{2\}\))</h4>' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
