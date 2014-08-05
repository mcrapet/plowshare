# Plowshare uploadable.ch module
# Copyright (c) 2014 Plowshare team
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

MODULE_UPLOADABLE_CH_REGEXP_URL='https\?://\(www\.\)\?uploadable\.ch/'

MODULE_UPLOADABLE_CH_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_UPLOADABLE_CH_DOWNLOAD_RESUME=no
MODULE_UPLOADABLE_CH_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_UPLOADABLE_CH_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_UPLOADABLE_CH_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
FOLDER,,folder,s=FOLDER,Folder to upload files into"
MODULE_UPLOADABLE_CH_UPLOAD_REMOTE_SUPPORT=yes

MODULE_UPLOADABLE_CH_LIST_OPTIONS=""
MODULE_UPLOADABLE_CH_LIST_HAS_SUBFOLDERS=no

MODULE_UPLOADABLE_CH_PROBE_OPTIONS=""

MODULE_UPLOADABLE_CH_DELETE_OPTIONS=""

# Static function. Proceed with login.
uploadable_ch_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local PAGE LOGIN_DATA LOGIN_RESULT

    LOGIN_DATA='userName=$USER&userPassword=$PASSWORD&autoLogin=on&action__login=normalLogin'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.php") || return

    if ! match 'Logging in' "$LOGIN_RESULT"; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a uploadable.ch file download URL and name
# $1: cookie file
# $2: uploadable.ch url
# stdout: file download link
#         file name
uploadable_ch_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(replace '://uploadable.ch' '://www.uploadable.ch' <<< "$2")
    local -r BASE_URL='http://www.uploadable.ch'

    local PAGE LOCATION WAIT_TIME

    if [ -n "$AUTH" ]; then
        uploadable_ch_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    if match 'File not available\|cannot be found on the server\|no longer available\|Page not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    if [ -n "$LOCATION" ]; then
        MODULE_UPLOADABLE_CH_DOWNLOAD_RESUME=yes

        echo "$LOCATION"
        return 0
    fi

    if match 'btn_premium_dl' "$PAGE"; then
        PAGE=$(curl -b "$COOKIE_FILE" \
            -d 'download=premium' \
            -i "$URL") || return

        MODULE_UPLOADABLE_CH_DOWNLOAD_RESUME=yes

        grep_http_header_location <<< "$PAGE" || return
        return 0
    fi

    if match 'var reCAPTCHA_publickey' "$PAGE"; then
        local PUBKEY WCI CHALLENGE WORD ID SHORTCODE
        # http://www.google.com/recaptcha/api/challenge?k=
        PUBKEY=$(parse 'var reCAPTCHA_publickey' "var reCAPTCHA_publickey='\([^']\+\)" <<< "$PAGE") || return
        SHORTCODE=$(parse . 'uploadable.ch/file/\([^/]\+\)' <<< "$URL") || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d 'downloadLink=wait' \
        "$URL") || return

    WAIT_TIME=$(parse_json 'waitTime' <<< "$PAGE") || return
    wait $WAIT_TIME || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d 'checkDownload=check' \
        "$URL") || return

    if match '"fail":"timeLimit"' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    if ! match '"success":"showCaptcha"' "$PAGE"; then
        return $ERR_FATAL
    fi

    if [ -n "$PUBKEY" ]; then
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "recaptcha_challenge_field=$CHALLENGE" \
            -d "recaptcha_response_field=$WORD" \
            -d "recaptcha_shortencode_field=$SHORTCODE" \
            "$BASE_URL/checkReCaptcha.php") || return

        if ! match '"success":1' "$PAGE"; then
            captcha_nack $ID
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
    fi

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d 'downloadLink=show' \
        "$URL") || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d 'download=normal' \
        -i "$URL") || return

    grep_http_header_location <<< "$PAGE" || return
}

# Check if specified folder name is valid.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base url
# stdout: folder ID
uploadable_ch_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    log_debug 'Getting folder data'

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d 'current_page=1' \
        -d 'extra=folderPanel' \
        "$BASE_URL/file-manager-expand-folder.php") || return

    FOLDERS=$(replace_all '{', $'\n{' <<< "$PAGE") || return
    FOLDERS=$(replace_all '}', $'}\n' <<< "$FOLDERS") || return

    FOLDERS_N=$(parse_all '"folderName":"' '"folderName":"\([^"]\+\)' <<< "$FOLDERS") || return

    if ! match "^$NAME$" "$FOLDERS_N"; then
        log_debug "Creating folder: '$NAME'"

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "newFolderName=$NAME" \
            -d 'createFolderDest=0' \
            "$BASE_URL/file-manager-action.php") || return

        if ! match '"success":true' "$PAGE"; then
            log_error 'Failed to create folder.'
            return $ERR_FATAL
        fi

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d 'current_page=1' \
            -d 'extra=folderPanel' \
            "$BASE_URL/file-manager-expand-folder.php") || return

        FOLDERS=$(replace_all '{', $'\n{' <<< "$PAGE") || return
        FOLDERS=$(replace_all '}', $'}\n' <<< "$FOLDERS") || return
    fi

    FOLDER_ID=$(parse "\"folderName\":\"$NAME\"" '"folderId":"\([^"]\+\)' <<< "$FOLDERS") || return

    log_debug "Folder ID: '$FOLDER_ID'"

    echo "$FOLDER_ID"
}

# Upload a file to uploadable.ch
# $1: cookie file
# $2: file path or remote url
# $3: remote filename
# stdout: download link
uploadable_ch_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.uploadable.ch'

    local PAGE UPLOAD_URL FILE_ID FILE_NAME DEL_CODE

    if [ -n "$AUTH" ]; then
        uploadable_ch_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(uploadable_ch_check_folder "$FOLDER" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        "$BASE_URL/index.php") || return

    if ! match_remote_url "$FILE"; then
        local MAX_SIZE SZ PREMIUM

        SZ=$(get_filesize "$FILE")

        PREMIUM=$(parse_quiet 'var isPremiumUser' "var isPremiumUser = '\([0-9]\+\)" <<< "$PAGE") || return
        if [ "$PREMIUM" = '1' ]; then
            MAX_SIZE='5368709120'
        else
            MAX_SIZE='2147483648'
        fi

        log_debug "Max size: $MAX_SIZE"

        if [ "$SZ" -gt "$MAX_SIZE" ]; then
            log_debug "File is bigger than $MAX_SIZE."
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    # Upload remote file
    if match_remote_url "$FILE"; then
        if ! match '^https\?://' "$FILE" && ! match '^ftp://' "$FILE"; then
            log_error 'Unsupported protocol for remote upload.'
            return $ERR_BAD_COMMAND_LINE
        fi

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "urls=$FILE" \
            -d 'remoteUploadFormType=web' \
            -d 'showPage=remoteUploadFormWeb.tpl' \
            "$BASE_URL/uploadremote.php") || return

        if ! match 'Upload Successful' "$PAGE"; then
            log_error 'Remote upload failed.'
            return $ERR_FATAL
        fi

        log_error 'Once remote upload completed, check your account for link.'
        return $ERR_ASYNC_REQUEST

    # Upload local file
    else
        UPLOAD_URL=$(parse 'var uploadUrl' "var uploadUrl = '\([^']\+\)" <<< "$PAGE") || return

        PAGE=$(curl_with_log -X PUT \
            -H "X-File-Name: $DESTFILE" \
            -H "X-File-Size: $SZ" \
            -H "Origin: $BASE_URL" \
            --data-binary "@$FILE" \
            "$UPLOAD_URL") || return

        DEL_CODE=$(parse_json 'deleteCode' <<< "$PAGE") || return
        FILE_NAME=$(parse_json 'fileName' <<< "$PAGE") || return
        FILE_ID=$(parse_json 'shortenCode' <<< "$PAGE") || return
    fi

    if [ -n "$FOLDER" ]; then
        local UPLOAD_ID

        log_debug "Moving file to folder '$FOLDER'..."

        # Get root folder content dorted by upload date DESC
        # Last uploaded file will be on top
        PAGE=$(curl -b "$COOKIE_FILE" \
            -d 'parent_folder_id=0' \
            -d 'current_page=1' \
            -d 'sort_field=2' \
            -d 'sort_order=DESC' \
            "$BASE_URL/file-manager-expand-folder.php") || return

        PAGE=$(replace_all '{', $'\n{' <<< "$PAGE") || return
        PAGE=$(replace_all '}', $'}\n' <<< "$PAGE") || return

        UPLOAD_ID=$(parse "$FILE_ID" '"uploadId":"\([^"]\+\)' <<< "$PAGE") || return

        log_debug "Upload ID: '$UPLOAD_ID'"

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "moveFolderId=$UPLOAD_ID" \
            -d "moveFolderDest=$FOLDER_ID" \
            -d 'CurrentFolderId=0' \
            "$BASE_URL/file-manager-action.php") || return

        if ! match '"successCount":1' "$PAGE"; then
            log_error 'Could not move file into folder.'
        fi
    fi

    echo "http://www.uploadable.ch/file/$FILE_ID/$FILE_NAME"
    echo "http://www.uploadable.ch/file/$FILE_ID/delete/$DEL_CODE"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: uploadable.ch url
# $3: requested capability list
# stdout: 1 capability per line
uploadable_ch_probe() {
    local -r URL=$(replace '://uploadable.ch' '://www.uploadable.ch' <<< "$2")
    local -r REQ_IN=$3
    local PAGE FILE_NAME FILE_SIZE REQ_OUT

    PAGE=$(curl -L "$URL") || return

    if match 'File not available\|cannot be found on the server\|no longer available\|Page not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_attr '"file_name"' 'title' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '"file_name"' '>(\([^)]\+\)' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a uploadable.ch web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
uploadable_ch_list() {
    local -r URL=$(replace '://uploadable.ch' '://www.uploadable.ch' <<< "$1")
    local -r REC=$2
    local PAGE LINKS NAMES

    PAGE=$(curl -L "$URL") || return

    if match 'File not available\|cannot be found on the server\|no longer available\|Page not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    NAMES=$(parse_all_quiet 'filename_normal' '">\(.*\) <span' <<< "$PAGE")
    LINKS=$(parse_all_attr_quiet 'filename_normal' 'href' <<< "$PAGE")

    list_submit "$LINKS" "$NAMES"
}

# Delete a file uploaded to uploadable.ch
# $1: cookie file (unused here)
# $2: delete url
uploadable_ch_delete() {
    local URL=$(replace '://uploadable.ch' '://www.uploadable.ch' <<< "$2")
    local PAGE

    PAGE=$(curl -L "$URL") || return

    if match 'File not available\|cannot be found on the server\|no longer available\|Page not found\|File Delete Fail' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    if ! match 'File Deleted' "$PAGE"; then
        return $ERR_FATAL
    fi
}
