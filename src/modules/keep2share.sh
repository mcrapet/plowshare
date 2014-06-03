#!/bin/bash
#
# keep2share.cc module
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
#
# Official API: https://github.com/keep2share/api

MODULE_KEEP2SHARE_REGEXP_URL='https\?://\(www\.\)\?\(keep2share\|k2s\|k2share\|keep2s\)\.cc/'

MODULE_KEEP2SHARE_DOWNLOAD_OPTIONS=""
MODULE_KEEP2SHARE_DOWNLOAD_RESUME=no
MODULE_KEEP2SHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_KEEP2SHARE_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account
FULL_LINK,,full-link,,Final link includes filename"
MODULE_KEEP2SHARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_KEEP2SHARE_PROBE_OPTIONS=""

# Static function. Check query answer
# $1: JSON data (like {"status":"xxx","code":ddd, ...}
# $?: 0 for success
keep2share_status() {
    local STATUS=$(parse_json 'status' <<< "$1")
    if [ "$STATUS" != 'success' ]; then
        local CODE=$(parse_json 'code' <<< "$1")
        local MSG=$(parse_json 'message' <<< "$1")
        log_error "Remote status: '$STATUS' with code $CODE."
        [ -z "$MSG" ] || log_error "Message: $MSG"
        return $ERR_FATAL
    fi
}

# Static function. Proceed with login
# $1: authentication
# $3: API URL
# stdout: auth token
keep2share_login() {
    local -r BASE_URL=$2
    local USER PASSWORD JSON

    split_auth "$1" USER PASSWORD || return
    JSON=$(curl --data '{"username":"'"$USER"'","password":"'"$PASSWORD"'"}' \
        "${BASE_URL}login") || return

    # {"status":"success","code":200,"auth_token":"li26v3nbhspn0tdth5hmd53j07"}
    # {"message":"Login attempt was exceed, wait...","status":"error","code":406}
    keep2share_status "$JSON" || return $ERR_LOGIN_FAILED

    parse_json 'auth_token' <<< "$JSON" && \
        log_debug "Successfully logged in as $USER member"
}

# Output an keep2share file download URL
# $1: cookie file
# $2: keep2share url
# stdout: real file download link
keep2share_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://k2s.cc'
    local PAGE FORM_HTML FORM_ID FORM_ACTION FILE_NAME PRE_URL

    PAGE=$(curl --location -c "$COOKIE_FILE" "$URL") || return

    # File not found or deleted
    if match 'File not found or deleted' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(parse_tag '^[[:space:]]*File:' 'span' <<< "$PAGE" | \
        html_to_utf8) || return

    FORM_HTML=$(grep_form_by_order "$PAGE") || return
    FORM_ID=$(parse_form_input_by_name 'slow_id' <<< "$FORM_HTML") || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return

    # request download
    PAGE=$(curl -b "$COOKIE_FILE" -d "slow_id=$FORM_ID" -d 'yt0' \
        "$BASE_URL$FORM_ACTION") || return

    # check for CAPTCHA
    if match 'id="captcha-form"' "$PAGE"; then
        log_error 'Captcha handling not implemented yet'
        return $ERR_FATAL
    fi

    if ! match 'btn-success.*Download' "$PAGE"; then
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    # get (redirecting) file URL
    PRE_URL=$(parse 'window.location.href' "'\([^']\+\)'" <<< "$PAGE") || return
    PAGE=$(curl --head -b "$COOKIE_FILE" "$BASE_URL/$PRE_URL") || return

    # output final url + file name
    grep_http_header_location <<< "$PAGE" || return
    echo "$FILE_NAME"
}

# Upload a file to keep2share.
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
keep2share_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r API_URL='http://keep2share.cc/api/v1/'
    local SZ TOKEN JSON FILE_ID

    # Sanity check
    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS

    local -r MAX_SIZE=524288000 # 500 MiB (free account)
    SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    TOKEN=$(keep2share_login "$AUTH_FREE" "$API_URL") || return
    log_debug "token: '$TOKEN'"

    JSON=$(curl --data '{"auth_token":"'$TOKEN'"}' \
        "${API_URL}GetUploadFormData") || return

    # {"status":"success","code":200,"form_action":"...","file_field":"Filedata", ...}
    keep2share_status "$JSON" || return

    local FORM_ACTION FILE_FIELD JSON2 NODE_NAME USER_ID HMAC EXPIRES

    FORM_ACTION=$(parse_json 'form_action' <<< "$JSON" ) || return
    FILE_FIELD=$(parse_json 'file_field' <<< "$JSON" ) || return

    JSON2=$(parse_json 'form_data' <<< "$JSON" ) || return
    log_debug "json2: '$JSON2'"

    NODE_NAME=$(parse_json 'nodeName' <<< "$JSON2" ) || return
    USER_ID=$(parse_json 'userId' <<< "$JSON2" ) || return
    HMAC=$(parse_json 'hmac' <<< "$JSON2" ) || return
    EXPIRES=$(parse_json 'expires' <<< "$JSON2" ) || return

    JSON=$(curl_with_log \
        -F "$FILE_FIELD=@$FILE;filename=$DEST_FILE" \
        -F "nodeName=$NODE_NAME" \
        -F "userId=$USER_ID" \
        -F "hmac=$HMAC" \
        -F "expires=$EXPIRES" \
        -F 'api_request=true' \
        "$FORM_ACTION") || return

    # Sanity check
    # <title>503 Service Temporarily Unavailable</title>
    if match '>503 Service Temporarily Unavailable<' "$JSON"; then
        log_error 'remote: service unavailable (HTTP 503)'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # {"user_file_id":"3ef8d474ad919","status":"success","status_code":200}
    keep2share_status "$JSON" || return

    FILE_ID=$(parse_json 'user_file_id' <<< "$JSON" ) || return
    if [ -z "$FULL_LINK" ]; then
        echo "http://k2s.cc/file/$FILE_ID"
    else
        echo "http://k2s.cc/file/$FILE_ID/$DEST_FILE"
    fi
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: keep2share url
# $3: requested capability list
# stdout: 1 capability per line
#
# Official API does not provide a anonymous check-link feature :(
# $ curl --data '{"ids"=["816bef5d35245"]}' http://keep2share.cc/api/v1/GetFilesInfo
keep2share_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_NAME

    PAGE=$(curl --location "$URL") || return

    # File not found or delete
    if match '<h.>Error 404</h.>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag '^[[:space:]]*File:' 'span' <<< "$PAGE" | html_to_utf8 && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag 'Size:' 'div' <<< "$PAGE") && \
            translate_size "${FILE_SIZE#Size: }" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse . 'file/\([[:alnum:]]\+\)/\?' <<< "$URL" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}
