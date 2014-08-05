# Plowshare filecloud.io module
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

MODULE_FILECLOUD_REGEXP_URL='http://\(www\.\)\?filecloud\.io/'

MODULE_FILECLOUD_DOWNLOAD_OPTIONS="
APIKEY,,apikey,s=APIKEY,Account apikey
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_FILECLOUD_DOWNLOAD_RESUME=yes
MODULE_FILECLOUD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FILECLOUD_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FILECLOUD_UPLOAD_OPTIONS="
APIKEY,,apikey,s=APIKEY,Account apikey
AUTH,a,auth,a=USER:PASSWORD,User account
PRIVATE,,private,,Mark file for personal use only
TAGS,,tags,s=TAGS,One or multiple tags for uploaded file (separated with comma)"
MODULE_FILECLOUD_UPLOAD_REMOTE_SUPPORT=no

MODULE_FILECLOUD_LIST_OPTIONS="
APIKEY,,apikey,s=APIKEY,Account apikey
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_FILECLOUD_LIST_HAS_SUBFOLDERS=no

MODULE_FILECLOUD_PROBE_OPTIONS=""

# curl wrapper to handle all json requests
# $@: curl arguments
# stdout: JSON content
filecloud_curl_json() {
    local PAGE STAT ERROR

    PAGE=$(curl "$@") || return

    STAT=$(parse_json 'status' <<< "$PAGE") || return

    if [ "$STAT" != 'ok' ]; then
        ERROR=$(parse_json 'message' <<< "$PAGE") || return

        if match 'set as private' "$ERROR" || \
            match 'private file' "$ERROR"; then
            log_error 'This tag or file is set as private and is only viewable by the owner.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif match 'no such user' "$ERROR"; then
            return $ERR_LOGIN_FAILED

        elif match '^no such' "$ERROR"; then
            return $ERR_LINK_DEAD

        else
            log_error "Remote error: $ERROR"
            return $ERR_FATAL
        fi
    fi

    echo "$PAGE"
}

# Fetch API key
# Official API: http://code.google.com/p/filecloud/
# $1: authentication data (user:pass)
# stdout: apikey
filecloud_api_fetch_apikey() {
    local -r AUTH=$1
    local USER PASSWORD PAGE

    split_auth "$AUTH" USER PASSWORD || return

    PAGE=$(filecloud_curl_json \
        -d "username=$USER" \
        -d "password=$PASSWORD" \
        'https://secure.filecloud.io/api-fetch_apikey.api') || return

    parse_json 'akey' <<< "$PAGE" || return
}

# Output a filecloud.io file download URL
# $1: cookie file
# $2: filecloud.io url
# stdout: file download link
filecloud_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://filecloud.io'

    local PREMIUM=0

    local PAGE UKEY FORM_AB FILE_URL AUTH_COOKIE CAPTCHA_DATA CAPTCHA
    local ERROR_CODE MESSAGES ERROR_TEXT

    if [ -z "$APIKEY" -a -n "$AUTH" ]; then
        APIKEY=$(filecloud_api_fetch_apikey "$AUTH") || return
    fi

    if [ -n "$APIKEY" ]; then
        AUTH_COOKIE="-b auth="$(uri_encode_strict <<< "$APIKEY")

        PAGE=$(filecloud_curl_json \
            -d "akey=$APIKEY" \
            'http://api.filecloud.io/api-fetch_account_details.api') || return

        PREMIUM=$(parse_json 'is_premium' <<< "$PAGE") || return
    fi

    UKEY=$(parse . '/\([[:alnum:]]\+\)$' <<< "$URL") || return

    if [ "$PREMIUM" = 1 ]; then
        PAGE=$(filecloud_curl_json \
            -d "akey=$APIKEY" \
            -d "ukey=$UKEY" \
            'http://api.filecloud.io/api-fetch_download_url.api') || return

        FILE_URL=$(parse_json 'download_url' <<< "$PAGE") || return

    else
        PAGE=$(curl -L $AUTH_COOKIE -c "$COOKIE_FILE" "$URL") || return

        ERROR_CODE=$(parse 'var __error' '__error[[:space:]]*=[[:space:]]*\([^;]\+\)' <<< "$PAGE") || return

        if [ "$ERROR_CODE" != 0 ]; then
            ERROR_MESSAGE=$(parse 'var __error_msg' '__error_msg[[:space:]]*=[[:space:]]*l10n\.\([^;]\+\)' <<< "$PAGE")

            if match 'FILES__REMOVED' "$ERROR_MESSAGE" ||
                match 'FILES__DOESNT_EXIST' "$ERROR_MESSAGE"; then
                return $ERR_LINK_DEAD

            elif match 'FILES__PRIVATE_MSG' "$ERROR_MESSAGE"; then
                log_error 'This file is set as private and is only viewable by the owner.'
                return $ERR_LINK_NEED_PERMISSIONS

            else
                MESSAGES=$(parse 'var l10n' "jQuery.parseJSON( '\(.*\)' );" <<< "$PAGE") || return
                ERROR_TEXT=$(parse_json "$ERROR_MESSAGE" <<< "$MESSAGES") || return

                log_error "Remote error: $ERROR_TEXT."

                return $ERR_FATAL
            fi
        fi

        FORM_AB=$(parse 'if( __ab == 1 ){var __ab1 = ' 'if( __ab == 1 ){var __ab1 = \([^;]\+\)' <<< "$PAGE") || return

        PAGE=$(filecloud_curl_json $AUTH_COOKIE -b "$COOKIE_FILE" \
            -d "ukey=$UKEY" \
            -d "__ab1=$FORM_AB" \
            "$BASE_URL/download-request.json") || return

        CAPTCHA=$(parse_json 'captcha' <<< "$PAGE") || return

        PAGE=$(curl $AUTH_COOKIE -b "$COOKIE_FILE" "$BASE_URL/download.html") || return

        while [ "$CAPTCHA" = 1 ]; do
            # captcha=1 on second loop means that previous captcha was wrong
            if [ -n "$ID" ]; then
                captcha_nack $ID
                log_error 'Wrong captcha'
                return $ERR_CAPTCHA
            fi

            local PUBKEY WCI CHALLENGE WORD ID
            PUBKEY=$(parse '__recaptcha_public' \
                "__recaptcha_public[[:space:]]*=[[:space:]]*'\([[:alnum:]_-.]\+\)" <<< "$PAGE") || return
            WCI=$(recaptcha_process $PUBKEY) || return
            { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

            CAPTCHA_DATA="-d ctype=recaptcha -d recaptcha_response=$WORD -d recaptcha_challenge=$CHALLENGE"

            PAGE=$(filecloud_curl_json $AUTH_COOKIE -b "$COOKIE_FILE" \
                -d "ukey=$UKEY" \
                -d "__ab1=$FORM_AB" \
                $CAPTCHA_DATA \
                "$BASE_URL/download-request.json") || return

            CAPTCHA=$(parse_json 'captcha' <<< "$PAGE") || return

            PAGE=$(curl $AUTH_COOKIE -b "$COOKIE_FILE" "$BASE_URL/download.html") || return
        done

        # Captcha is optional sometimes
        [ -n "$ID" ] && captcha_ack $ID

        FILE_URL=$(parse_attr 'downloadBtn' 'href' <<< "$PAGE") || return
    fi

    echo "$FILE_URL"
}

# Check if specified tag name(s) is valid.
# There cannot be two tags with the same name.
# $1: tag name(s) selected by user
# $2: apikey
# $3: base url
# stdout: tag ID
filecloud_check_tag() {
    local NAMES=$1
    local -r APIKEY=$(uri_encode_strict <<< "$2")
    local -r BASE_URL=$3

    local PAGE TAGS_LIST TAGS TAGS_ID

    log_debug 'Getting tag IDs...'

    PAGE=$(curl -b "auth=$APIKEY" "$BASE_URL/tags-manager.html") || return

    TAGS_LIST=$(parse 'var __tagsQueue' "jQuery.parseJSON( '{\(.*\)}' );" <<< "$PAGE") || return
    TAGS_LIST=$(replace_all '},' $'},\n' <<< "$TAGS_LIST")
    TAGS=$(parse_json 'name' <<< "$TAGS_LIST") || return

    while read NAME; do
        if ! matchi "^$NAME$" "$TAGS"; then
            log_debug "Creating tag: '$NAME'"

            PAGE=$(filecloud_curl_json -b "auth=$APIKEY" \
                -d "name=$NAME" \
                "$BASE_URL/tags-add_p.json") || return

            PAGE=$(curl -b "auth=$APIKEY" "$BASE_URL/tags-manager.html") || return

            TAGS_LIST=$(parse 'var __tagsQueue' "jQuery.parseJSON( '{\(.*\)}' );" <<< "$PAGE") || return
            TAGS_LIST=$(replace_all '},' $'},\n' <<< "$TAGS_LIST")
            TAGS=$(parse_json 'name' <<< "$TAGS_LIST") || return

            if ! matchi "^$NAME$" "$TAGS"; then
                log_error "Could not create tag '$NAME'."
                return $ERR_FATAL
            fi
        fi

        TAG_ID=$(parse "\"name\":\"$NAME\"" '"tkey":"\([^"]\+\)' <<< "$TAGS_LIST") || return
        TAGS_ID=$TAGS_ID$'\n'$TAG_ID
    done <<< "$NAMES"

    strip_and_drop_empty_lines "$TAGS_ID"
}

# Upload a file to filecloud.io
# $1: cookie file
# $2: file path or remote url
# $3: remote filename
# stdout: download link
filecloud_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r MAX_SIZE=2097152000 # 2000 MiB
    local -r BASE_URL='http://filecloud.io'

    local PAGE UP_URL UKEY TAGS_ID STAT ERROR APIKEY_ENC

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "File is bigger than $MAX_SIZE."
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -z "$APIKEY" -a -n "$AUTH" ]; then
        APIKEY=$(filecloud_api_fetch_apikey "$AUTH") || return
    fi

    if [ -n "$TAGS" ]; then
        TAGS=$(replace_all ',' $'\n' <<< "$TAGS")
        TAGS=$(strip_and_drop_empty_lines "$TAGS")

        TAGS_ID=$(filecloud_check_tag "$TAGS" "$APIKEY" "$BASE_URL") || return
    fi

    PAGE=$(filecloud_curl_json \
        'http://api.filecloud.io/api-fetch_upload_url.api') || return

    UP_URL=$(parse_json 'upload_url' <<< "$PAGE") || return

    PAGE=$(curl_with_log \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        -F "akey=$APIKEY" \
        "$UP_URL") || return

    STAT=$(parse_json 'status' <<< "$PAGE") || return

    if [ "$STAT" != 'ok' ]; then
        ERROR=$(parse_json 'message' <<< "$PAGE") || return
        log_error "Upload failed. Remote error: $ERROR."
        return $ERR_FATAL
    fi

    UKEY=$(parse_json 'ukey' <<< "$PAGE") || return

    if [ -n "$TAGS" ]; then
        log_debug 'Setting tags...'

        APIKEY_ENC=$(uri_encode_strict <<< "$APIKEY")

        while read TAG_ID_CUR; do
            PAGE=$(filecloud_curl_json -b "auth=$APIKEY_ENC" \
                -F "ukey=$UKEY" \
                -F "tkey=$TAG_ID_CUR" \
                "$BASE_URL/tags-add_relation_p.json") || return
        done <<< "$TAGS_ID"
    fi

    if [ -n "$PRIVATE" ]; then
        log_debug 'Setting private flag...'

        APIKEY_ENC=$(uri_encode_strict <<< "$APIKEY")

        PAGE=$(filecloud_curl_json -b "auth=$APIKEY_ENC" \
            -F "ukey=$UKEY" \
            "$BASE_URL/files-change_atype_p.json") || return
    fi

    echo "$BASE_URL/$UKEY"
}

# List a filecloud.io tag
# $1: filecloud.io folder link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
filecloud_list() {
    local -r URL=$1

    local PAGE ERROR TKEY FILES_LIST NAMES LINKS

    TKEY=$(parse . '/_\([[:alnum:]]\+\)$' <<< "$URL") || return

    if [ -z "$APIKEY" -a -n "$AUTH" ]; then
        APIKEY=$(filecloud_api_fetch_apikey "$AUTH") || return
    fi

    if [ -n "$APIKEY" ]; then
        PAGE=$(filecloud_curl_json \
            -d "akey=$APIKEY" \
            -d "tkey=$TKEY" \
            'http://api.filecloud.io/api-fetch_tag_details.api') || return

        FILES_LIST=$(parse . '"files":\(.*\)},"status"' <<< "$PAGE") || return

    else
        PAGE=$(curl "$URL") || return

        ERROR=$(parse_quiet '<i class="icon-ban-circle"></i>' '</i> \(.*\)$' <<< "$PAGE")

        if match 'this tag is set as private' "$ERROR"; then
            log_error 'This tag is set as private and is only viewable by the tag owner.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif match 'no such tag' "$ERROR"; then
            return $ERR_LINK_DEAD

        elif [ -n "$ERROR" ]; then
            log_error "Remote error: $ERROR"
            return $ERR_FATAL
        fi

        FILES_LIST=$(parse 'var __filesQueue' "jQuery.parseJSON( '\(.*\)' );" <<< "$PAGE") || return
    fi

    NAMES=$(parse_json 'name' 'split' <<< "$FILES_LIST") || return
    LINKS=$(parse_json 'url' 'split' <<< "$FILES_LIST") || return

    list_submit "$LINKS" "$NAMES" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: filecloud.io url
# $3: requested capability list
# stdout: 1 capability per line
filecloud_probe() {
    local -r URL=$2
    local -r REQ_IN=$3

    local PAGE FILE_SIZE UKEY

    UKEY=$(parse . '/\([[:alnum:]]\+\)$' <<< "$URL") || return

    PAGE=$(filecloud_curl_json \
        -d "ukey=$UKEY" \
        'http://api.filecloud.io/api-check_file.api') || return

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_json 'name' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_json 'size' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
