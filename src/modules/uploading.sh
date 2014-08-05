# Plowshare uploading.com module
# Copyright (c) 2010-2013 Plowshare team
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

MODULE_UPLOADING_REGEXP_URL='http://\([[:alnum:]]\+\.\)\?uploading\.com/'

MODULE_UPLOADING_DOWNLOAD_OPTIONS=""
MODULE_UPLOADING_DOWNLOAD_RESUME=no
MODULE_UPLOADING_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_UPLOADING_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_UPLOADING_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"
MODULE_UPLOADING_UPLOAD_REMOTE_SUPPORT=no

MODULE_UPLOADING_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
uploading_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local -r ENC_BASE_URL=$(uri_encode_strict <<< "$BASE_URL/")
    local LOGIN_DATA JSON PAGE ID NAME

    LOGIN_DATA="email=\$USER&password=\$PASSWORD&back_url=$ENC_BASE_URL&remember=on"
    JSON=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
       "$BASE_URL/general/login_form/?ajax" -b "$COOKIE_FILE" \
       -H 'X-Requested-With: XMLHttpRequest') || return

    # Note: Cookies "remembered_user", "u", "autologin" get set on successful login
    if [ "$JSON" != '{"redirect":"http:\/\/uploading.com\/"}' ]; then
        if ! match 'Incorrect e-mail\/password combination.' "$JSON"; then
            log_error "Unexpected remote error: $ERROR"
        fi

        return $ERR_LOGIN_FAILED
    fi

    # Determine account information
    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/account") || return
    ID=$(echo "$PAGE" | parse_tag 'id="account_link"' 'a') || return
    NAME=$(echo "$PAGE" | parse_form_input_by_id 'nick_name') || return

    log_debug "Successfully logged in as member '$ID' ($NAME)"
}

# Output a uploading file download URL (anonymous)
# $1: cookie file
# $2: uploading.com url
# stdout: real file download link
uploading_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://uploading.com'
    local PAGE WAIT CODE PASS JSON FILE_NAME FILE_URL

    # Force language to English
    PAGE=$(curl -L -c "$COOKIE_FILE" -b 'lang=1' "$URL") || return

    # <h2>OOPS! Looks like file not found.</h2>
    if match 'file not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi


    # <h2>Maximum File Size Limit</h2>
    # <h2>File access denied</h2>
    if matchi 'File \(Size Limit\|access denied\)' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS

    # <h2>Parallel Download</h2>
    elif match '[Yy]our IP address is currently' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE

    # <h2>Daily Download Limit</h2>
    elif matchi 'daily download limit' "$PAGE"; then
        echo 600
        return $ERR_LINK_TEMP_UNAVAILABLE

    # <h2>File is still uploading</h2>
    elif matchi 'File is still uploading' "$PAGE"; then
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    CODE=$(echo "$PAGE" | parse '[[:space:]]code:' ":[[:space:]]*[\"']\([^'\"]*\)") || return
    PASS=false
    log_debug "code: $CODE"

    FILE_NAME=$(echo "$PAGE" | parse '>Filemanager' '>\([^<]*\)</' 1)

    # Get wait time
    WAIT=$(echo "$PAGE" | parse_tag '"timer_secs"' span) || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d 'action=second_page' -d "code=$CODE" \
        "$BASE_URL/files/get/?ajax") || return

    wait $((WAIT+1)) || return

    JSON=$(curl -b "$COOKIE_FILE" -d 'action=get_link' \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d "code=$CODE" -d "pass=$PASS" \
        "$BASE_URL/files/get/?ajax") || return

    # {"answer":{"link":"http:\/\/uploading.com\/files\/thankyou\/... "}}
    FILE_URL=$(echo "$JSON" | parse_json link) || return

    PAGE=$(curl -b "$COOKIE_FILE" "$FILE_URL") || return
    FILE_URL=$(echo "$PAGE" | parse_attr '=.file_form' action) || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to Uploading.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: uploading.com download link
uploading_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://uploading.com'
    local PAGE JSON UPLOAD_URL MAX_SIZE SIZE SESSION_ID UPLOAD_ID FILE_ID

    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS
    uploading_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return

    MAX_SIZE=$(echo "$PAGE" | parse '^[[:space:]]*max_file_size' \
        'max_file_size:[[:space:]]*\([[:digit:]]\+\)') || return
    UPLOAD_URL=$(echo "$PAGE" | parse '^[[:space:]]*upload_url' \
        "upload_url:[[:space:]]*'\([^']\+\)'") || return
    SESSION_ID=$(parse_cookie 'SID' < "$COOKIE_FILE") || return

    # Check file size
    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # from 'http://uploading.com/static/js/upload_file.js':
    #
    #    fu.progress.id = '';
    #
    #    for (var i = 0; i < 32; i += 1) {
    #        fu.progress.id += Math.floor(Math.random() * 16).toString(16);
    #    }
    UPLOAD_ID=$(random h 32) || return

    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -F 'folder_id=0' \
        -F "SID=$SESSION_ID" \
        -F 'is_simple=1' \
        -F "file=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        "$UPLOAD_URL?X-Progress-ID=$UPLOAD_ID") || return

    # ... {"answer":"2111c52b","folder_id":0,"file_id":54671204} ...
    FILE_ID=$(echo "$PAGE" | parse_json_quiet 'file_id')

    if [ -z "$FILE_ID" ]; then
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    JSON=$(curl -b "$COOKIE_FILE" -H 'X-Requested-With: XMLHttpRequest' \
        -F 'action=get_file_info' -F "file_id=$FILE_ID" \
        "$BASE_URL/files/nmanager/?ajax") || return

    # Extract and output file link
    echo "$JSON" | parse_json 'link' || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: uploading.com url
# $3: requested capability list
# stdout: 1 capability per line
uploading_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L -b 'lang=1' "$URL") || return

    # <h2>OOPS! Looks like file not found.</h2>
    if match 'file not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse 'filemanager_action"' '<li>\([^<]*\)' 1 <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse 'size tip_container' \
            'tip_container">\([^<]*\)') && translate_size "$FILE_SIZE" && \
                REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
