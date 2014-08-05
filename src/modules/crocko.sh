# Plowshare crocko.com module
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

MODULE_CROCKO_REGEXP_URL='https\?://\(www\.\)\?crocko\.com/'

MODULE_CROCKO_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
API,,api,,Use API to upload file
API_KEY,,api-key,s=API_KEY,Provide API key to use instead of login:pass. Can be used without --api option."
MODULE_CROCKO_DOWNLOAD_RESUME=no
MODULE_CROCKO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_CROCKO_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_CROCKO_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
FOLDER,,folder,s=FOLDER,Folder to upload files into
PREMIUM,,premium,,Make file inaccessible to non-premium users"
MODULE_CROCKO_UPLOAD_REMOTE_SUPPORT=no

MODULE_CROCKO_LIST_OPTIONS=""
MODULE_CROCKO_LIST_HAS_SUBFOLDERS=yes

MODULE_CROCKO_PROBE_OPTIONS=""

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
crocko_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local PAGE LOGIN_DATA LOGIN_RESULT LOGIN_FLAG

    LOGIN_DATA='success_llocation=&login=$USER&password=$PASSWORD&remember=1'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/accounts/login") || return

    LOGIN_FLAG=$(parse_cookie_quiet 'logacc' < "$COOKIE_FILE")

    if [ "$LOGIN_FLAG" != '1' ]; then
        return $ERR_LOGIN_FAILED
    fi
}

# Get API key
# $1: authentication
# $2: base URL
crocko_login_api() {
    local -r AUTH=$1
    local -r BASE_URL=$2

    local PAGE USER PASSWORD ERROR_CODE MESSAGE

    split_auth "$AUTH" USER PASSWORD || return

    PAGE=$(curl \
        -H 'Accept: application/atom+xml' \
        -d "login=$USER" \
        -d "password=$PASSWORD" \
        "$BASE_URL/apikeys") || return

    ERROR_CODE=$(parse_tag '^<' 'title' <<< "$PAGE") || return
    MESSAGE=$(parse_tag 'content' <<< "$PAGE") || return

    if [ "$ERROR_CODE" = 'apikey' ]; then
        echo "$MESSAGE"
        return 0
    elif [ "$ERROR_CODE" = 'errorWrongCredentials' ]; then
        return $ERR_LOGIN_FAILED
    else
        echo "Unknown remote error $ERROR_CODE: $MESSAGE"
        return $ERR_FATAL
    fi
}

# Output a crocko.com file download URL
# $1: cookie file
# $2: crocko.com url
# stdout: real file download link
crocko_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL=$(basename_url "$URL")

    local PAGE WAIT_TIME CAPTCHA_SCRIPT FORM_CAPTCHA FILE_URL FILE_ID FILE_NAME

    if [ -n "$API" ] && [ -z "$AUTH" -a -z "$API_KEY" ]; then
        log_error 'You must provide -a logn:pass or --api-key for API.'
        return $ERR_BAD_COMMAND_LINE
    fi

    if [ -n "$AUTH" -o -n "$API_KEY" ]; then
        local FILE_CODE ERROR_CODE MESSAGE

        FILE_CODE=$(parse . 'crocko.com/\([^/]\+\)' <<< "$URL") || return

        if [ -z "$API_KEY" ]; then
            if [ -z "$API" ]; then
                log_error 'Use --api option or provide --api-key to use account.'
                return $ERR_BAD_COMMAND_LINE
            fi

            API_KEY=$(crocko_login_api "$AUTH" 'http://api.crocko.com') || return
        fi

        PAGE=$(curl \
            -H "Accept: application/atom+xml" \
            -H "Authorization: $API_KEY" \
            "http://api.crocko.com/files/$FILE_CODE;DirectLink") || return

        if match 'Wrong apikey' "$PAGE"; then
            log_error 'Wrong API key.'
            return $ERR_LOGIN_FAILED
        fi

        ERROR_CODE=$(parse_tag_quiet '^<' 'title' <<< "$PAGE")
        MESSAGE=$(parse_tag_quiet 'content' <<< "$PAGE") || return

        if [ -z "$ERROR_CODE" ]; then
            FILE_NAME=$(parse_tag_all 'title' <<< "$PAGE") || return
            FILE_NAME=$(last_line <<< "$FILE_NAME")

            FILE_URL=$(parse_attr 'link' 'href' <<< "$PAGE") || return

            MODULE_CROCKO_DOWNLOAD_RESUME=yes

            echo "$FILE_URL"
            echo "$FILE_NAME"

            return 0
        fi

        if [ "$ERROR_CODE" = 'errorPermissionDenied' ]; then
            log_error 'Your account is not premium.'
            return $ERR_LINK_NEED_PERMISSIONS
        elif [ "$ERROR_CODE" = 'errorFileNotFound' ] || \
            [ "$ERROR_CODE" = 'errorFileInNoDownloadedStatus' ]; then
            return $ERR_LINK_DEAD
        else
            echo "Unknown remote error $ERROR_CODE: $MESSAGE"
            return $ERR_FATAL
        fi
    fi

    PAGE=$(curl -c "$COOKIE_FILE" -b 'language=en' "$URL") || return

    if match '<title>Crocko.com 404</title>' "$PAGE" || \
        match 'File not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match 'You need Premium membership to download this file' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    elif match 'There is another download in progress from your IP' "$PAGE"; then
        log_error 'There is another download in progress from your IP.'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    if ! match 'Recaptcha.create("' "$PAGE"; then
        WAIT_TIME=$(parse "w='" "w='\([0-9]\+\)" <<< "$PAGE") || return
        CAPTCHA_SCRIPT=$(parse "u='" "u='\([^']\+\)" <<< "$PAGE") || return

        if (( $WAIT_TIME > 300 )); then
            echo "$WAIT_TIME"
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        wait $WAIT_TIME || return

        PAGE=$(curl -b "$COOKIE_FILE" -b 'language=en' "$BASE_URL$CAPTCHA_SCRIPT") || return
    fi

    if match 'There is another download in progress from your IP' "$PAGE"; then
        log_error 'There is another download in progress from your IP.'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FILE_URL=$(parse_attr 'file_contents' 'action' <<< "$PAGE") || return
    FILE_ID=$(parse_form_input_by_name 'id' <<< "$PAGE") || return

    local PUBKEY WCI CHALLENGE WORD ID

    PUBKEY=$(parse 'Recaptcha.create("' 'Recaptcha.create("\([^"]\+\)' <<< "$PAGE") || return
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    FORM_CAPTCHA="-d recaptcha_challenge_field=$CHALLENGE -d recaptcha_response_field=$WORD"

    # Temporary file & HTTP headers
    local TMP_FILE TMP_FILE_H

    TMP_FILE=$(create_tempfile '.crocko') || return
    TMP_FILE_H=$(create_tempfile '.crocko_h') || return

    # Need to download now, no other way to check captcha
    curl_with_log \
        -D "$TMP_FILE_H" \
        -o "$TMP_FILE" \
        -b "$COOKIE_FILE" \
        $FORM_CAPTCHA \
        -d "id=$FILE_ID" \
        "$FILE_URL" || return

    if  match "text/html" "$(grep_http_header_content_type < "$TMP_FILE_H")"; then
        rm -f "$TMP_FILE_H" "$TMP_FILE"
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    FILE_NAME=$(grep_http_header_content_disposition < "$TMP_FILE_H") || return
    rm -f "$TMP_FILE_H"

    echo "file://$TMP_FILE"
    echo "$FILE_NAME"
}

# Upload a file to crocko.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
crocko_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.crocko.com'

    local PAGE SESSION_ID FILE_URL FILE_DEL_URL FILE_ID

    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif [ -n "$PREMIUM" ]; then
            log_error 'You must be registered to set premium only flag.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    if [ -n "$AUTH" ]; then
        crocko_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
        SESSION_ID=$(parse_cookie 'PHPSESSID' < "$COOKIE_FILE") || return
    fi

    PAGE=$(curl_with_log \
        -F "Filename=$DEST_FILE" \
        -F "PHPSESSID=$SESSION_ID" \
        -F 'Upload=Submit Query' \
        -F "Filedata=@$FILE;filename=$DEST_FILE" \
        'http://wwwupload.crocko.com/accounts/upload_backend/perform/ajax') || return

    if match 'You exceed upload limit for Free account' "$PAGE"; then
        log_error 'You exceed upload limit for Free account.'
        return $ERR_FATAL
    fi

    FILE_URL=$(parse_attr 'input' 'value' <<< "$PAGE") || return
    #FILE_DEL_URL=$(parse_tag 'class="del"' 'a' <<< "$PAGE") || return

    if [ -n "$AUTH" ] && [ -n "$FOLDER" -o -n "$PREMIUM" ]; then
        FILE_ID=$(parse_quiet 'createFolder(' 'createFolder(\([0-9]\+\)' <<< "$PAGE")

        [ -z "$FILE_ID" ] && log_error 'Could not get folder ID.'
    fi

    if [ -n "$FILE_ID" -a -n "$FOLDER" ]; then
        local FOLDERS FOLDER_ID

        FOLDERS=$(parse_all_tag_quiet 'option' <<< "$PAGE")
        FOLDERS=$(delete_last_line <<< "$FOLDERS")
        FOLDERS=$(parse_all_quiet '|---' '|--- \(.*\)$' <<< "$FOLDERS")

        if ! match "^$FOLDER$" "$FOLDERS"; then
            log_debug 'Creating folder...'

            PAGE=$(curl -b "$COOKIE_FILE" \
                -H 'X-Requested-With: XMLHttpRequest' \
                "$BASE_URL/upload/change_folder/0/$FILE_ID/$FOLDER") || return

            if match '^[0-9]\+$' "$PAGE"; then
                FOLDER_ID="$PAGE"
            fi
        else
            FOLDER_ID=$(parse_attr_quiet "<option .*|--- $FOLDER" 'value' <<< "$PAGE")
        fi

        if [ -z "$FOLDER_ID" ]; then
            log_error 'Could not get folder ID.'
        else
            log_debug 'Moving file to folder...'

            PAGE=$(curl -b "$COOKIE_FILE" \
                -H 'X-Requested-With: XMLHttpRequest' \
                "$BASE_URL/upload/change_folder/$FOLDER_ID/$FILE_ID") || return

            if [ "$PAGE" != "$FOLDER_ID" ]; then
                log_error 'Could not move file into folder.'
            fi
        fi
    fi

    if [ -n "$FILE_ID" -a -n "$PREMIUM" ]; then
        local RND=$(random d 6)

        log_debug 'Setting premium only flag...'

        PAGE=$(curl -b 'language=en' -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d "files[]=$FILE_ID" \
            -d 'filetype=P' \
            "$BASE_URL/accounts/filemanage/file_change_type?f=b&rnd=$RND") || return

        if [ "$PAGE" != 'Action performed' ]; then
            log_error 'Could not set premium only flag.'
        fi
    fi

    echo "$FILE_URL"
    # Files deletion does not work for some reason
    #echo "$FILE_DEL_URL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: crocko.com url
# $3: requested capability list
# stdout: 1 capability per line
crocko_probe() {
    local -r URL=$2
    local -r REQ_IN=$3

    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -b 'language=en' "$URL") || return

    if match '<title>Crocko.com 404</title>' "$PAGE" || \
        match 'File not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'Download:' 'strong' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '<span class="tip1">' \
        'class="inner">\([^<]\+\)' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a crocko.com web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
crocko_list() {
    local -r URL=$1
    local -r REC=$2

    local PAGE LINKS NAMES

    PAGE=$(curl -b 'language=en' "$URL") || return
    PAGE=$(replace_all '<tr>' $'\n''<tr>' <<< "$PAGE")

    LINKS=$(parse_all_attr_quiet '>download</a>' 'href' <<< "$PAGE")
    NAMES=$(parse_all_tag_quiet '>download</a>' 'div' <<< "$PAGE")
    if [ -z "$LINKS" ]; then
        return $ERR_LINK_DEAD
    fi

    list_submit "$LINKS" "$NAMES"

    if [ -n "$REC" ]; then
        local FOLDERS FOLDER

        FOLDERS=$(parse_all_attr_quiet '/f/' 'href' <<< "$PAGE")

        while read FOLDER; do
            [ -z "$FOLDER" ] && continue
            log_debug "Entering sub folder: $FOLDER"
            crocko_list "$FOLDER" "$REC" && RET=0
        done <<< "$FOLDERS"
    fi
}
