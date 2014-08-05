# Plowshare bitshare.com module
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

MODULE_BITSHARE_REGEXP_URL='http://\(www\.\)\?bitshare\.com/'

MODULE_BITSHARE_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_BITSHARE_DOWNLOAD_RESUME=yes
MODULE_BITSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_BITSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_BITSHARE_UPLOAD_OPTIONS="
METHOD,,method,s=METHOD,Upload method (openapi or form, default: openapi)
AUTH,a,auth,a=USER:PASSWORD,User account
HASHKEY,,hashkey,s=HASHKEY,Hashkey used in openapi (override -a/--auth)"
MODULE_BITSHARE_UPLOAD_REMOTE_SUPPORT=yes

MODULE_BITSHARE_DELETE_OPTIONS=""

MODULE_BITSHARE_PROBE_OPTIONS=""

# Login to bitshare (HTML form)
# $1: authentication
# $2: cookie file
bitshare_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local LOGIN

    post_login "$AUTH" "$COOKIE_FILE" \
        'user=$USER&password=$PASSWORD&rememberlogin=&submit=Login' \
        "http://bitshare.com/login.html" -b "$COOKIE_FILE" > /dev/null || return
    LOGIN=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if test -z "$LOGIN"; then
        return $ERR_LOGIN_FAILED
    else
        log_debug 'successfully logged in'
    fi
}

# Output a bitshare file download URL
# $1: cookie file
# $2: bitshare url
# stdout: real file download link
bitshare_download() {
    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://bitshare.com'
    local FILE_ID POST_URL WAIT AJAXDL DATA RESPONSE
    local NEED_RECAPTCHA FILE_URL FILENAME

    FILE_ID=$(echo "$URL" | parse_quiet 'bitshare' 'bitshare\.com/files/\([^/]\+\)/')
    if test -z "$FILE_ID"; then
        FILE_ID=$(echo "$URL" | parse 'bitshare' 'bitshare\.com/?f=\(.\+\)$') || return
    fi

    log_debug "file id=$FILE_ID"
    POST_URL="$BASE_URL/files-ajax/$FILE_ID/request.html"

    # Set website language to english (language_selection=EN)
    curl -c "$COOKIEFILE" -o /dev/null "$BASE_URL/?language=EN" || return

    # Login
    if test "$AUTH"; then
        bitshare_login "$AUTH" "$COOKIEFILE" || return
    fi

    # Add cookie entries: last_file_downloaded, trafficcontrol
    RESPONSE=$(curl -i -b "$COOKIEFILE" -c "$COOKIEFILE" "$URL") || return

    # Error - File not available
    ! match 'File not available' "$RESPONSE" || return $ERR_LINK_DEAD


    # Download limit
    if match "You reached your hourly traffic limit\." "$RESPONSE"; then
        WAIT=$(echo "$RESPONSE" | parse '<span id="blocktimecounter">' \
            '<span id="blocktimecounter">\([[:digit:]]\+\) seconds\?</span>')
        echo $((WAIT))
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match "Sorry, you cant download more then [[:digit:]]\+ files\? at time\." "$RESPONSE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Note: filename is <h1> tag might be truncated
    FILENAME=$(echo "$RESPONSE" | parse 'http://bitshare\.com/files/' \
        'value="http://bitshare\.com/files/'"$FILE_ID"'/\(.*\)\.html"') || return

    # Premium account direct download
    FILE_URL=$(echo "$RESPONSE" | grep_http_header_location_quiet) || return
    if [ "$FILE_URL" ]; then
        log_debug 'using premium direct download'
        echo "$FILE_URL"
        echo "$FILENAME"
        return
    fi

    # Add cookie entry: ads_download=1
    curl -b "$COOKIEFILE" -c "$COOKIEFILE" -o /dev/null \
        "$BASE_URL/getads.html" || return

    # Get ajaxdl id
    AJAXDL=$(echo "$RESPONSE" | parse 'var ajaxdl = ' \
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
        log_debug 'need recaptcha'
    else
        log_debug 'no recaptcha needed'
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
        log_debug 'correct captcha'
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
    if [ -z "$METHOD" -o "$METHOD" = 'openapi' ]; then
        if [ -n "$HASHKEY" ]; then
            [ -z "$AUTH" ] || \
                log_error 'Both --hashkey & --auth_free are defined. Taking hashkey.'
        elif [ -n "$AUTH" ]; then
            # Login to openapi
            local USER PASSWORD PASSWORD_HASH RESPONSE HASHKEY
            split_auth "$AUTH" USER PASSWORD || return

            PASSWORD_HASH=$(md5 "$PASSWORD") || return
            RESPONSE=$(curl --form-string "user=$USER" \
                --form-string "password=$PASSWORD_HASH" \
                'http://bitshare.com/api/openapi/login.php') || return
            if ! match '^SUCCESS:' "$RESPONSE"; then
                return $ERR_LOGIN_FAILED
            fi
            HASHKEY="${RESPONSE:8}"
            log_debug "successful login to openapi as $USER member, hashkey: $HASHKEY"
        fi
        bitshare_upload_openapi "$HASHKEY" "$2" "$3" || return

    elif [ "$METHOD" = form ]; then
        if match_remote_url "$2"; then
            log_error 'Remote upload is not supported with this method. Use openapi method.'
            return $ERR_FATAL
        fi
        bitshare_upload_form "$AUTH" "$1" "$2" "$3" || return

    else
        log_error 'Unknow method (check --method parameter)'
        return $ERR_FATAL
    fi
}

# Upload a file to bitshare using openapi
# Official API: http://bitshare.com/openAPI.html
# $1: hashkey
# $2: file path or remote url
# $3: remote filename
bitshare_upload_openapi() {
    local HASHKEY=$1
    local FILE=$2
    local REMOTE_FILENAME=$3
    local UPLOAD_URL='http://bitshare.com/api/openapi/upload.php'

    local RESPONSE MAX_SIZE SIZE FILESERVER_URL DOWNLOAD_URL DELETE_URL

    if match_remote_url "$FILE"; then
        if [ -z "$HASHKEY" ]; then
            log_error 'Remote upload requires an account'
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        # Remote url upload
        local REMOTE_UPLOAD_KEY
        RESPONSE=$(curl --form-string 'action=addRemoteUpload' \
            -F "hashkey=$HASHKEY" \
            -F "url=$FILE" \
            "$UPLOAD_URL") || return
        if ! match '^SUCCESS:' "$RESPONSE"; then
            log_error "Failed in adding url: $RESPONSE"
            return $ERR_FATAL
        fi

        REMOTE_UPLOAD_KEY="${RESPONSE:8}"
        log_debug "remote upload key: $REMOTE_UPLOAD_KEY"

        while :; do
            wait 60 || return

            RESPONSE=$(curl --form-string 'action=remoteUploadStatus' \
                -F "hashkey=$HASHKEY" \
                -F "key=$REMOTE_UPLOAD_KEY" \
                "$UPLOAD_URL") || return
            if ! match '^SUCCESS:' "$RESPONSE"; then
                log_error "Failed in retrieving upload status: $RESPONSE"
                break
            fi

            RESPONSE=${RESPONSE:8}
            if match '^Finished#' "$RESPONSE"; then
                local FILE_URL=${RESPONSE:9}

                # Do we need to rename file ?
                if [ "$REMOTE_FILENAME" != dummy ]; then
                    local RESPONSE2 FILEID_INT FILEID_URL

                    UPLOAD_URL='http://bitshare.com/api/openapi/filestructure.php'
                    RESPONSE2=$(curl --form-string 'action=getfiles' \
                        --form-string 'mainfolder=0' \
                        -F "hashkey=$HASHKEY" \
                        "$UPLOAD_URL") || return

                    FILEID_URL=$(echo "$FILE_URL" | parse . '/files/\([^/]\+\)')
                    FILEID_INT=$(echo "$RESPONSE2" | parse_quiet "$FILEID_URL" '^\([^#]\+\)')
                    if [ -n "$FILEID_INT" ]; then
                        RESPONSE2=$(curl --form-string 'action=renamefile' \
                            -F "hashkey=$HASHKEY" \
                            -F "name=$REMOTE_FILENAME" \
                            -F "file=$FILEID_INT" \
                            "$UPLOAD_URL") || return
                        if ! match '^SUCCESS:' "$RESPONSE2"; then
                            log_error "Failed to rename file: $RESPONSE2"
                        fi
                    else
                        log_debug "can't find file id, cannot rename"
                    fi
                fi

                echo "$FILE_URL"
                return 0

            elif match '^Failed#' "$RESPONSE"; then
                log_error "Remote download failed: $RESPONSE"
                break

            else # Pending, Processing, Downloading
                log_debug "status: ${RESPONSE/\#/: }"
            fi
        done
        return $ERR_FATAL
    fi

    # Get max file size
    # RESPONSE=SUCCESS:[max. filesize]#[max. entries]
    RESPONSE=$(curl --form-string 'action=maxFileSize' \
        -F "hashkey=$HASHKEY" \
        "$UPLOAD_URL") || return
    if ! match '^SUCCESS:' "$RESPONSE"; then
        log_error "Failed in getting max file size: $RESPONSE"
        return $ERR_FATAL
    fi

    RESPONSE=${RESPONSE:8}
    MAX_SIZE=${RESPONSE%%#*}
    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Get fileserver url
    # RESPONSE=SUCCESS:[fileserver url]
    RESPONSE=$(curl --form-string 'action=getFileserver' \
        "$UPLOAD_URL") || return
    if ! match '^SUCCESS:' "$RESPONSE"; then
        log_error "Failed in getting file server url: $RESPONSE"
        return $ERR_FATAL
    fi

    FILESERVER_URL="${RESPONSE:8}"
    log_debug "file server: $FILESERVER_URL"

    # Upload
    # RESPONSE=SUCCESS:[downloadlink]#[bblink]#[htmllink]#[shortlink]#[deletelink]
    RESPONSE=$(curl_with_log \
        -F "hashkey=$HASHKEY" \
        -F "filesize=$SIZE" \
        -F "file=@$FILE;filename=$REMOTE_FILENAME" \
        "$FILESERVER_URL") || return

    if ! match '^SUCCESS:' "$RESPONSE"; then
        log_error "Failed in uploading: $RESPONSE"
        return $ERR_FATAL
    fi

    DOWNLOAD_URL=$(echo "$RESPONSE" | parse '#' '^SUCCESS:\([^#]\+\)') || return
    DELETE_URL=${RESPONSE##*#}
    echo "$DOWNLOAD_URL"
    echo "$DELETE_URL"
}

# Upload file to bitshare using html form
# $1: authentication
# $2: cookie file
# $3: file path
# $4: remote filename
bitshare_upload_form() {
    local AUTH=$1
    local COOKIEFILE=$2
    local FILE=$3
    local REMOTE_FILENAME=$4
    local BASE_URL='http://bitshare.com'

    local HTML DOWNLOAD_URL DELETE_URL

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
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Extract form parameters
    local FORM ACTION PROGRESS_KEY USERGROUP_KEY UPLOAD_IDENTIFIER RESPONSE
    FORM=$(grep_form_by_id "$HTML" uploadform) || return
    ACTION=$(echo "$FORM" | parse_form_action) || return
    PROGRESS_KEY=$(echo "$FORM" | parse_form_input_by_id 'progress_key') || return
    USERGROUP_KEY=$(echo "$FORM" | parse_form_input_by_id 'usergroup_key') || return
    UPLOAD_IDENTIFIER=$(echo "$FORM" | parse_form_input_by_name 'UPLOAD_IDENTIFIER') || return

    # Upload
    RESPONSE=$(curl_with_log -L --referer "$BASE_URL/" -b "$COOKIEFILE" \
        --form-string APC_UPLOAD_PROGRESS="$PROGRESS_KEY" \
        --form-string APC_UPLOAD_USERGROUP="$USERGROUP_KEY" \
        --form-string UPLOAD_IDENTIFIER="$UPLOAD_IDENTIFIER" \
        -F file[]='@/dev/null;filename=' \
        -F file[]="@$FILE;filename=$REMOTE_FILENAME" \
        "${ACTION}?X-Progress-ID=undefined$(random h 32)") || return

    DOWNLOAD_URL=$(echo "$RESPONSE" | parse \
        '<td style="text-align:right">Download:</td>' 'value="\([^"]\+\)"' 1) || return
    DELETE_URL=$(echo "$RESPONSE" | parse \
        '<td style="text-align:right">Delete link:</td>' 'value="\([^"]\+\)"' 1) || return

    echo "$DOWNLOAD_URL"
    echo "$DELETE_URL"
}

# Delete a file from Bitshare
# $1: cookie file (unused here)
# $2: bitshare (delete) link
bitshare_delete() {
    local -r URL=$2
    local PAGE

    PAGE=$(curl -b 'language_selection=EN' "$URL") || return
    match '<p class="error">Wrong Link</p>' "$PAGE" && return $ERR_LINK_DEAD

    # Note: Page tries to show captcha. It's broken, but deletion works anyway.
    if match '<h1>Delete File?</h1>' "$PAGE"; then
        PAGE=$(curl -d 'sum' -d 'submit=Delete' "$URL") || return

        if match '<p class="success">File deleted!</p>' "$PAGE"; then
            return 0
        fi
    fi

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file
# $2: bitshare url
# $3: requested capability list
# stdout: 1 capability per line
bitshare_probe() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_NAME FILE_SIZE

    PAGE=$(curl -c "$COOKIE_FILE" -b 'language_selection=EN' "$URL") || return

    ! match 'File not available' "$PAGE" || return $ERR_LINK_DEAD

    REQ_OUT=c

    # Filename can be truncated
    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(echo "$PAGE" | parse_tag title)
        FILE_NAME=${FILE_NAME#Download }
        FILE_NAME=${FILE_NAME% - BitShare.com - Free File Hosting and Cloud Storage}
        test "$FILE_NAME" && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse '<h1>' \
            '[[:space:]]-[[:space:]]\([[:digit:]]\+\(\.[[:digit:]]\+\)\?[[:space:]][KM]B\)yte') && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
