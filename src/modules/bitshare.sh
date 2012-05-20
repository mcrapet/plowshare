#!/bin/bash
#
# bitshare.com module
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

MODULE_BITSHARE_REGEXP_URL="http://\(www\.\)\?bitshare\.com/"

MODULE_BITSHARE_DOWNLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free account"
MODULE_BITSHARE_DOWNLOAD_RESUME=yes
MODULE_BITSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_BITSHARE_UPLOAD_OPTIONS="
METHOD,,method:,METHOD,Upload method (openapi or form, default: openapi)
AUTH,a:,auth:,USER:PASSWORD,Account
HASHKEY,,hashkey:,HASHKEY,Hashkey used in openapi"
MODULE_BITSHARE_UPLOAD_REMOTE_SUPPORT=yes

# Login to bitshare (HTML form)
# $1: authentification
# $2: cookie file
bitshare_login() {
    local AUTH COOKIEFILE LOGIN
    AUTH="$1"
    COOKIEFILE="$2"
    post_login "$AUTH" "$COOKIEFILE" \
        'user=$USER&password=$PASSWORD&rememberlogin=&submit=Login' \
        "http://bitshare.com/login.html" > /dev/null
    LOGIN=$(parse_cookie_quiet 'login' < "$COOKIEFILE")
    if test -z "$LOGIN"; then
        return $ERR_LOGIN_FAILED
    else
        log_debug "successfully logged in"
    fi
}

# Output a bitshare file download URL
# $1: cookie file
# $2: bitshare url
# stdout: real file download link
bitshare_download() {
    eval "$(process_options bitshare "$MODULE_BITSHARE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://bitshare.com'
    local FILE_ID POST_URL HTML WAIT AJAXDL DATA RESPONSE
    local NEED_RECAPTCHA FILE_URL FILENAME

    FILE_ID=$(echo "$URL" | parse_quiet 'bitshare' 'bitshare\.com\/files\/\([^/]\+\)\/')
    if test -z "$FILE_ID"; then
        FILE_ID=$(echo "$URL" | parse 'bitshare' 'bitshare\.com\/?f=\(.\+\)$') || return
    fi

    log_debug "file id=$FILE_ID"
    POST_URL="$BASE_URL/files-ajax/$FILE_ID/request.html"

    # Set website language to english (language_selection=EN)
    curl -c "$COOKIEFILE" -o /dev/null "$BASE_URL/?language=EN" || return

    # Login
    if test "$AUTH_FREE"; then
        bitshare_login "$AUTH_FREE" "$COOKIEFILE" || return
    fi

    # Add cookie entries: last_file_downloaded, trafficcontrol
    HTML=$(curl -b "$COOKIEFILE" -c "$COOKIEFILE" "$URL") || return

    # File unavailable
    if match "<h1>Error - File not available</h1>" "$HTML"; then
        return $ERR_LINK_DEAD

    # Download limit
    elif match "You reached your hourly traffic limit\." "$HTML"; then
        WAIT=$(echo "$HTML" | parse '<span id="blocktimecounter">' \
            '<span id="blocktimecounter">\([[:digit:]]\+\) seconds\?<\/span>')
        echo $((WAIT))
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match "Sorry, you cant download more then [[:digit:]]\+ files\? at time\." "$HTML"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Note: filename is <h1> tag might be truncated
    FILENAME=$(echo "$HTML" | parse 'http:\/\/bitshare\.com\/files\/' \
        'value="http:\/\/bitshare\.com\/files\/'"$FILE_ID"'\/\(.*\)\.html"') || return

    # Add cookie entry: ads_download=1
    curl -b "$COOKIEFILE" -c "$COOKIEFILE" -o /dev/null \
        "$BASE_URL/getads.html" || return

    # Get ajaxdl id
    AJAXDL=$(echo "$HTML" | parse 'var ajaxdl = ' \
        'var ajaxdl = "\([^"]\+\)";') || return

    # Retrieve parameters
    # Example: file:60:1
    DATA="request=generateID&ajaxid=$AJAXDL"
    RESPONSE=$(curl -b "$COOKIEFILE" --referer "$URL" --data "$DATA" \
        "$POST_URL") || return

    if match '^ERROR' "$RESPONSE"; then
        log_error "failed in retrieving parameters: $RESPONSE"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    WAIT=$(echo "$RESPONSE" | parse ':' ':\([[:digit:]]\+\):') || return
    NEED_RECAPTCHA=$(echo "$RESPONSE" | parse ':' ':\([^:]\+\)$') || return

    if [ "$NEED_RECAPTCHA" -eq 1 ]; then
        log_debug "need recaptcha"
    else
        log_debug "no recaptcha needed"
    fi

    wait $WAIT seconds || return

    # ReCaptcha
    if [ "$NEED_RECAPTCHA" -eq 1 ]; then
        local PUBKEY WCI CHALLENGE WORD ID RECAPTCHA_RESULT
        PUBKEY='6LdtjrwSAAAAACepq37DE6GDMp1TxvdbW5ui0rdE'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        DATA="request=validateCaptcha&ajaxid=$AJAXDL&recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD"
        RECAPTCHA_RESULT=$(curl -b "$COOKIEFILE" --referer "$URL" --data "$DATA" \
            "$POST_URL") || return

        if ! match '^SUCCESS:\?' "$RECAPTCHA_RESULT"; then
            log_error 'Wrong captcha'
            captcha_nack $ID
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug "correct captcha"
    fi

    # Get file url
    DATA="request=getDownloadURL&ajaxid=$AJAXDL"
    RESPONSE=$(curl -b "$COOKIEFILE" --referer "$URL" --data "$DATA" \
        "$POST_URL") || return

    if match 'ERROR#' "$RESPONSE"; then
        log_error "getting file url fail: $RESPONSE"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FILE_URL=$(echo "$RESPONSE" | parse 'SUCCESS#' '^SUCCESS#\(.*\)$')

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to bitshare
# Need md5sum or md5 when using the openapi method
# $1: cookie file
# $2: file path or remote url
# $3: remote filename
# stdout: bitshare download link and delete link
bitshare_upload() {
    eval "$(process_options bitshare "$MODULE_BITSHARE_UPLOAD_OPTIONS" "$@")"
    if [ -z "$METHOD" ] || [ "$METHOD" = "openapi" ]; then
        if [ -z "$HASHKEY" ] && [ "$AUTH" ]; then
            # Login to openapi
            local USER PASSWORD PASSWORD_HASH RESPONSE HASHKEY
            USER="${AUTH%%:*}"
            PASSWORD="${AUTH#*:}"
            if check_exec md5sum; then
                # GNU/Linux uses md5sum
                PASSWORD_HASH=$(echo -n "$PASSWORD" | md5sum)
                PASSWORD_HASH=${PASSWORD_HASH%% *}
            elif check_exec md5; then
                # BSD uses md5
                PASSWORD_HASH=$(md5 -qs "$PASSWORD")
            else
                log_error "cannot find md5 calculator"
                return $ERR_SYSTEM
            fi
            RESPONSE=$(curl --form-string user="$USER" \
                --form-string password="$PASSWORD_HASH" \
                "http://bitshare.com/api/openapi/login.php") || return
            if ! match '^SUCCESS:' "$RESPONSE"; then
                return $ERR_LOGIN_FAILED
            fi
            HASHKEY="${RESPONSE:8}"
            log_debug "successful login to openapi, hashkey: $HASHKEY"
        fi
        bitshare_upload_openapi "$HASHKEY" "$2" "$3" || return
    elif [ "$METHOD" = form ]; then
        if match_remote_url "$2"; then
            log_error "remote upload is not supported in form method"
            return $ERR_FATAL
        fi
        bitshare_upload_form "$AUTH" "$1" "$2" "$3" || return
    fi
}

# Upload a file to bitshare using openapi
# $1: hashkey
# $2: file path or remote url
# $3: remote filename
bitshare_upload_openapi() {
    local HASHKEY FILE REMOTE_FILENAME UPLOAD_URL RESPONSE
    HASHKEY="$1"
    FILE="$2"
    REMOTE_FILENAME="$3"
    UPLOAD_URL=http://bitshare.com/api/openapi/upload.php

    if match_remote_url "$FILE"; then
        if [ -z "$HASHKEY" ]; then
            log_error "Remote upload requires an account"
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        # Remote url upload
        local REMOTE_UPLOAD_KEY
        RESPONSE=$(curl -F hashkey="$HASHKEY" -F action=addRemoteUpload \
            --form-string url="$FILE" "$UPLOAD_URL") || return
        if ! match '^SUCCESS:' "$RESPONSE"; then
            log_error "Failed in adding url: $RESPONSE"
            return $ERR_FATAL
        fi
        REMOTE_UPLOAD_KEY="${RESPONSE:8}"
        log_debug "remote upload key: $REMOTE_UPLOAD_KEY"

        while true; do
            wait 60 || return
            RESPONSE=$(curl -F hashkey="$HASHKEY" -F action=remoteUploadStatus \
                --form-string key="$REMOTE_UPLOAD_KEY" "$UPLOAD_URL") || return
            if ! match '^SUCCESS:' "$RESPONSE"; then
                log_error "Failed in retrieving upload status: $RESPONSE"
                return $ERR_FATAL
            fi
            RESPONSE="${RESPONSE:8}"
            if match '^Finished#' "$RESPONSE"; then
                echo "${RESPONSE:9}"
                return
            elif match '^Failed#' "$RESPONSE"; then
                log_error "Remote download failed: $RESPONSE"
                return $ERR_FATAL
            else # Pending, Processing, Downloading
                log_debug "status: $RESPONSE"
            fi
        done
    fi

    # Get max file size
    # RESPONSE=SUCCESS:[max. filesize]#[max. entries]
    local MAX_SIZE SIZE FILESERVER_URL DOWNLOAD_URL DELETE_URL
    RESPONSE=$(curl -F hashkey="$HASHKEY" -F action=maxFileSize "$UPLOAD_URL") || return
    if ! match '^SUCCESS:' "$RESPONSE"; then
        log_error "Failed in getting max file size: $RESPONSE"
        return $ERR_FATAL
    fi
    RESPONSE="${RESPONSE:8}"
    MAX_SIZE="${RESPONSE%%#*}"
    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_error "File should not be larger than $MAX_SIZE bytes"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Get fileserver url
    # RESPONSE=SUCCESS:[fileserver url]
    RESPONSE=$(curl -F action=getFileserver "$UPLOAD_URL") || return
    if ! match '^SUCCESS:' "$RESPONSE"; then
        log_error "Failed in getting file server url: $RESPONSE"
        return $ERR_FATAL
    fi
    FILESERVER_URL="${RESPONSE:8}"
    log_debug "file server: $FILESERVER_URL"

    # Upload
    # RESPONSE=SUCCESS:[downloadlink]#[bblink]#[htmllink]#[shortlink]#[deletelink]
    RESPONSE=$(curl_with_log -F hashkey="$HASHKEY" -F filesize=$SIZE \
        -F "file=@$FILE;filename=$REMOTE_FILENAME" \
        "$FILESERVER_URL") || return

    if ! match '^SUCCESS:' "$RESPONSE"; then
        log_error "Failed in uploading: $RESPONSE"
        return $ERR_FATAL
    fi
    DOWNLOAD_URL=$(echo "$RESPONSE" | parse '#' '^SUCCESS:\([^#]\+\)') || return
    DELETE_URL=$(echo "$RESPONSE" | parse '#' '#\([^#]\+\)$') || return
    echo "$DOWNLOAD_URL"
    echo "$DELETE_URL"
}

# Upload file to bitshare using html form
# $1: authenfitication
# $2: cookie file
# $3: file path
# $4: remote filename
bitshare_upload_form() {
    local AUTH COOKIEFILE FILE REMOTE_FILENAME BASE_URL HTML DOWNLOAD_URL DELETE_URL
    AUTH="$1"
    COOKIEFILE="$2"
    FILE="$3"
    REMOTE_FILENAME="$4"
    BASE_URL=http://bitshare.com

    # Set website language to english (language_selection=EN)
    curl -c "$COOKIEFILE" -o /dev/null "$BASE_URL/?language=EN" || return

    # Login
    if test "$AUTH"; then
        bitshare_login "$AUTH" "$COOKIEFILE" || return
    fi

    HTML=$(curl -b "$COOKIEFILE" -c "$COOKIEFILE" "$BASE_URL") || return

    # Get file size
    local SIZE MAX_SIZE
    MAX_SIZE=$(echo "$HTML" | parse 'Maximum file size' \
        'Maximum file size \([[:digit:]]\+\) Mbyte') || return
    MAX_SIZE=$((MAX_SIZE*1048576))
    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_error "File should not be larger than $MAX_SIZE bytes"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Extract form parameters
    local FORM ACTION PROGRESS_KEY USERGROUP_KEY UPLOAD_IDENTIFIER RESPONSE
    FORM=$(grep_form_by_id "$HTML" uploadform) || return
    ACTION="$(echo "$FORM" | parse_form_action)?X-Progress-ID=undefined$(random h 32)" || return
    PROGRESS_KEY=$(echo "$FORM" | parse_form_input_by_id 'progress_key') || return
    USERGROUP_KEY=$(echo "$FORM" | parse_form_input_by_id 'usergroup_key') || return
    UPLOAD_IDENTIFIER=$(echo "$FORM" | parse_form_input_by_name 'UPLOAD_IDENTIFIER') || return
    log_debug "form action: $ACTION"
    log_debug "progress_key: $PROGRESS_KEY"
    log_debug "usergroup_key: $USERGROUP_KEY"
    log_debug "upload_identifier: $UPLOAD_IDENTIFIER"

    # Upload
    RESPONSE=$(curl_with_log -L --referer "$BASE_URL/" -b "$COOKIEFILE" \
        --form-string APC_UPLOAD_PROGRESS="$PROGRESS_KEY" \
        --form-string APC_UPLOAD_USERGROUP="$USERGROUP_KEY" \
        --form-string UPLOAD_IDENTIFIER="$UPLOAD_IDENTIFIER" \
        -F file[]='@/dev/null;filename=' \
        -F file[]="@$FILE;filename=$REMOTE_FILENAME" "$ACTION") || return
    DOWNLOAD_URL=$(echo "$RESPONSE" | \
        parse_line_after '<td style="text-align:right">Download:<\/td>' 'value="\([^"]\+\)"') || return
    DELETE_URL=$(echo "$RESPONSE" | \
        parse_line_after '<td style="text-align:right">Delete link:<\/td>' 'value="\([^"]\+\)"') || return
    echo "$DOWNLOAD_URL"
    echo "$DELETE_URL"
}
