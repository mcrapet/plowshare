# Plowshare sockshare.com module
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

MODULE_SOCKSHARE_REGEXP_URL='http://\(www\.\)\?sockshare\.com/\(file\|public\|embed\)/[[:alnum:]]\+'

MODULE_SOCKSHARE_DOWNLOAD_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_SOCKSHARE_DOWNLOAD_RESUME=yes
MODULE_SOCKSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_SOCKSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_SOCKSHARE_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
FOLDER,,folder,s=FOLDER,Folder to upload files into
ASYNC,,async,,Asynchronous remote upload (only start upload, don't wait for link)
METHOD,,method,s=METHOD,Upload method (API or form, default: API)"
MODULE_SOCKSHARE_UPLOAD_REMOTE_SUPPORT=yes

MODULE_SOCKSHARE_LIST_OPTIONS=""
MODULE_SOCKSHARE_LIST_HAS_SUBFOLDERS=no

MODULE_SOCKSHARE_DELETE_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"

MODULE_SOCKSHARE_PROBE_OPTIONS=""

# Failsafe curl wrapper to make frequent overload errors less lethal
sockshare_curl_failsafe() {
    local PAGE TRY

    for TRY in 1 2 3 4 5; do
        PAGE=$(curl "$@") || return

        if ! match 'Request could not be processed' "$PAGE"; then
            echo "$PAGE"
            return 0
        fi

        log_debug "Server cannot process the request, maybe due to overload. Retrying... [$TRY]"
        wait 10 || return
    done

    log_error 'Server cannot process the request, maybe due to overload.'
    return $ERR_LINK_TEMP_UNAVAILABLE
}

# Static function. Proceed with login.
sockshare_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local PAGE LOGIN_DATA LOGIN_RESULT LOCATION CAPTCHA_URL CAPTCHA_IMG

    PAGE=$(sockshare_curl_failsafe -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        "$BASE_URL/authenticate.php?login") || return

    CAPTCHA_URL=$(echo "$PAGE" | parse_attr '/include/captcha.php' src) || return
    CAPTCHA_IMG=$(create_tempfile '.jpg') || return

    curl -b "$COOKIE_FILE" -e "$BASE_URL/authenticate.php?login" \
        -o "$CAPTCHA_IMG" "$BASE_URL$CAPTCHA_URL" || return

    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG") || return
    { read WORD; read ID; } <<<"$WI"
    rm -f "$CAPTCHA_IMG"

    LOGIN_DATA="user=\$USER&pass=\$PASSWORD&captcha_code=$WORD&login_submit=Login"
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/authenticate.php?login" \
        -i -b "$COOKIE_FILE" \
        -e "$BASE_URL/authenticate.php?login") || return

    if match 'Request could not be processed' "$LOGIN_RESULT"; then
        log_error 'Server cannot process the request, maybe due to overload.'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    LOCATION=$(echo "$LOGIN_RESULT" | grep_http_header_location_quiet)

    if ! match '^cp\.php' "$LOCATION"; then
        log_error 'Wrong captcha'
        captcha_nack $ID
        return $ERR_LOGIN_FAILED
    fi

    log_debug 'Correct captcha'
    captcha_ack $ID
}

# Output a sockshare.com file download URL and name
# $1: cookie file
# $2: sockshare.com url
# stdout: file download link
#         file name
sockshare_download() {
    local -r COOKIE_FILE=$1
    local -r URL=${2/\/embed\//\/file\/}
    local -r BASE_URL='http://www.sockshare.com'

    local PAGE LOCATION GET_FILE_URL FILE_NAME WAIT_TIME
    local FORM_HTML FORM_HASH FORM_CONFIRM

    if ! match '/file/' "$URL"; then
        log_error 'Invalid URL format'
        return $ERR_BAD_COMMAND_LINE
    fi

    PAGE=$(sockshare_curl_failsafe -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return
    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    if [ "$LOCATION" = '../?404' ]; then
        return $ERR_LINK_DEAD
    elif [ -n "$LOCATION" ]; then
        log_error 'Unknown error'
        return $ERR_FATAL
    fi

    FILE_NAME=$(parse 'var name' '"\([^"]\+\)"' <<< "$PAGE") || return
    WAIT_TIME=$(parse_all 'var wait_count ' '=[[:space:]]*\([0-9]\+\);' <<< "$PAGE" | last_line) || return

    if [ $WAIT_TIME -gt 1 ]; then
        wait $WAIT_TIME || return
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_HASH=$(parse_form_input_by_name 'hash' <<< "$FORM_HTML") || return
    FORM_CONFIRM=$(parse_form_input_by_name 'confirm' <<< "$FORM_HTML") || return

    PAGE=$(sockshare_curl_failsafe -e "$URL" -b "$COOKIE_FILE" \
        -d "hash=$FORM_HASH" -d "confirm=$FORM_CONFIRM"  "$URL") || return

    if match 'This file requires a password. Please enter it.' "$PAGE"; then
        if [ -z $LINK_PASSWORD ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        PAGE=$(sockshare_curl_failsafe -i -e "$URL" -b "$COOKIE_FILE" \
            -d "file_password=$LINK_PASSWORD" "$URL") || return

        LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

        if [ -n "$LOCATION" ]; then
            return $ERR_LINK_PASSWORD_REQUIRED
        fi
    fi

    GET_FILE_URL=$(parse_attr 'get_file\.php' 'href' <<< "$PAGE") || return

    PAGE=$(sockshare_curl_failsafe -i -e "$URL" -b "$COOKIE_FILE" \
        "$BASE_URL$GET_FILE_URL") || return

    grep_http_header_location <<< "$PAGE" || return
    echo "$FILE_NAME"
}

# Check for active remote uploads
# $1: cookie file (logged into account)
# $2: base url
sockshare_check_remote_uploads() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE LAST_UPLOAD_STATUS

    PAGE=$(sockshare_curl_failsafe -b "$COOKIE_FILE" "$BASE_URL/cp.php?action=external_upload") || return

    # <div class="status"><span class=upload_status>Status_Info</span></div>
    LAST_UPLOAD_STATUS=$(echo "$PAGE" | parse_tag 'class="status"' div | parse_attr class) || return

    [ "$LAST_UPLOAD_STATUS" = 'dq_status_transfering' ]
}

# Check if specified folder name is valid.
# There cannot be two folder with the same name.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base url
# stdout: folder ID
#         folder HASH
sockshare_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local PAGE FOLDER_ID FOLDER_HASH RES_MESSAGE

    log_debug 'Getting folder data'

    PAGE=$(sockshare_curl_failsafe -b "$COOKIE_FILE" "$BASE_URL/cp.php") || return

    # Create folder if not exist
    # <a ... class="folder_link">Name</a>
    if ! match "class=\"folder_link\">$NAME<" "$PAGE"; then
        log_debug "Creating folder: '$NAME'"

        PAGE=$(sockshare_curl_failsafe -b "$COOKIE_FILE" -L \
            -d "new_folder_name=$NAME" \
            -d "new_folder_desc=" \
            -d "new_folder_parent=0" \
            -d "create_folder=Create Folder" \
            "$BASE_URL/cp.php?action=new_folder") || return

        RES_MESSAGE=$(echo "$PAGE" | parse_tag_quiet "class='message t_" div)

        if [ "$RES_MESSAGE" != 'New folder has been added.' ]; then
            if [ -z "$RES_MESSAGE" ]; then
                log_error 'Could not create folder.'
            else
                log_error "Create folder error: $RES_MESSAGE"
            fi
            return $ERR_FATAL
        fi
    fi

    FOLDER_ID=$(echo "$PAGE" | parse "class=\"folder_link\">$NAME<" 'id=\([[:digit:]]\+\)"' 3) || return
    FOLDER_HASH=$(echo "$PAGE" | parse "class=\"folder_link\">$NAME<" 'folder=\([^"]\+\)"') || return

    echo "$FOLDER_ID"
    echo "$FOLDER_HASH"
}

# Upload a file to sockshare.com
# $1: cookie file
# $2: file path or remote url
# $3: remote filename
# stdout: download link
sockshare_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r MAX_SIZE=1073741824 # 1024 MiB

    # Sanity checks
    if [ -n "$ASYNC" ]; then
        if ! match_remote_url "$FILE"; then
            log_error 'Cannot upload local files asynchronously.'
            return $ERR_BAD_COMMAND_LINE

        elif [ "$DEST_FILE" != 'dummy' ]; then
            log_error 'Cannot rename a file uploaded asynchronously.'
            return $ERR_BAD_COMMAND_LINE

        elif [ -n "$FOLDER" ]; then
            log_error 'Cannot move a file uploaded asynchronously.'
            return $ERR_BAD_COMMAND_LINE

        elif [ -n "$LINK_PASSWORD" ]; then
            log_error 'Cannot set password to the file uploaded asynchronously.'
            return $ERR_BAD_COMMAND_LINE
        fi
    fi

    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif match_remote_url "$FILE"; then
            log_error 'You must be registered to do remote uploads.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

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

    if [ -z "$METHOD" -o "$METHOD" = 'api' ]; then
        if match_remote_url "$FILE"; then
            log_error 'Remote upload is not supported with this method. Use form method.'
            return $ERR_FATAL
        elif [ -n "$LINK_PASSWORD" ]; then
            log_error 'Password is not supported with this method. Use form method.'
            return $ERR_FATAL
        elif [ -n "$ASYNC" ]; then
            log_error 'Asynchronous upload is not supported with this method. Use form method.'
            return $ERR_FATAL
        fi

        sockshare_upload_api "$FILE" "$DEST_FILE" || return
    elif [ "$METHOD" = 'form' ]; then
        sockshare_upload_form "$COOKIE_FILE" "$FILE" "$DEST_FILE" || return
    else
        log_error 'Unknow method (check --method parameter)'
        return $ERR_FATAL
    fi
}

# Upload a file to sockshare.com using api
# Official API: http://www.sockshare.com/apidocs.php
# NOTE: Does not support remote upload and password protection
# $1: file path
# $2: remote filename
# stdout: download link
sockshare_upload_api() {
    local -r FILE=$1
    local -r DEST_FILE=$2
    local PAGE LINK_DL
    local RES_MESSAGE USER PASSWORD

    if [ -n "$AUTH" ]; then
        split_auth "$AUTH" USER PASSWORD || return
    else
       USER='anonymous'
       PASSWORD='anonymous'
    fi

    PAGE=$(curl_with_log \
            -F "file=@$FILE;filename=$DESTFILE" \
            -F "user=$USER" \
            -F "password=$PASSWORD" \
            -F "convert=1" \
            -F "folder=$FOLDER" \
            'http://upload.sockshare.com/uploadapi.php') || return

    if match 'Request could not be processed' "$PAGE"; then
        log_error 'Server cannot process the request, maybe due to overload.'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    RES_MESSAGE=$(echo "$PAGE" | parse_tag message) || return

    if [ "$RES_MESSAGE" = 'File Uploaded Successfully' ]; then
        LINK_DL=$(echo "$PAGE" | parse_tag link) || return
        echo "$LINK_DL"
        return 0
    elif [ "$RES_MESSAGE" = 'Wrong username or password' ]; then
        return $ERR_LOGIN_FAILED
    fi

    log_error "Remote error: $RES_MESSAGE"
    return $ERR_FATAL
}

# Upload file to sockshare.com using html form
# $1: cookie file
# $2: file path
# $3: remote filename
sockshare_upload_form() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.sockshare.com'
    local PAGE FOLDER_ID FOLDER_HASH LINK_DL FILE_ID RES_MESSAGE

    if [ -n "$AUTH" ]; then
        sockshare_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    if [ -n "$FOLDER" ]; then
        local FOLDER_DATA
        FOLDER_DATA=$(sockshare_check_folder "$FOLDER" "$COOKIE_FILE" "$BASE_URL") || return
        { read FOLDER_ID; read FOLDER_HASH; } <<<"$FOLDER_DATA"
    fi

    # Upload remote file
    if match_remote_url "$FILE"; then
        local TRY UP_REMOTE_STATUS FILE_ID

        if ! match '^https\?://' "$FILE" && ! match '^ftp://' "$FILE"; then
            log_error 'Unsupported protocol for remote upload.'
            return $ERR_BAD_COMMAND_LINE
        fi

        # current_folder option doesen't work
        PAGE=$(sockshare_curl_failsafe -b "$COOKIE_FILE" -L \
            -e "$BASE_URL/cp.php?action=external_upload" \
            -d "external_url=$FILE" \
            -d "current_folder=0" \
            -d "download_external=Download File" \
            "$BASE_URL/cp.php?action=external_upload") || return

        RES_MESSAGE=$(echo "$PAGE" | parse_tag_quiet "class='message t_" div)

        if [ "$RES_MESSAGE" != 'File has been queued for download, and will appear in your file list when its done.' ]; then
            if [ -z "$RES_MESSAGE" ]; then
                log_error 'Could not set remote upload.'
            else
                log_error "Set remote upload error: $RES_MESSAGE"
            fi
            return $ERR_FATAL
        fi

        # If this is an async upload, we are done
        if [ -n "$ASYNC" ]; then
            log_error 'Once remote upload completed, check your account for link.'
            return $ERR_ASYNC_REQUEST
        fi

        # Keep checking progress
        TRY=1
        while sockshare_check_remote_uploads "$COOKIE_FILE" "$BASE_URL"; do
            log_debug "Wait for server to download the file... [$((TRY++))]"
            wait 15 || return # arbitrary, short wait time
        done

        # Check last finished upload status
        PAGE=$(sockshare_curl_failsafe --get -b "$COOKIE_FILE" -d 'action=external_upload' \
            "$BASE_URL/cp.php") || return

        UP_REMOTE_STATUS=$(echo "$PAGE" | parse_tag '<div class="status">' span) || return

        if [ "$UP_REMOTE_STATUS" != 'Done' ]; then
            log_error "Upload error: $UP_REMOTE_STATUS"
            return $ERR_FATAL
        fi

        # Find link
        PAGE=$(sockshare_curl_failsafe -b "$COOKIE_FILE" "$BASE_URL/cp.php") || return

        LINK_DL=$(echo "$PAGE" | parse_attr "href=.$BASE_URL/file/" href) || return
        FILE_ID=$(parse . '^.*/\(.*\)$' <<< "$LINK_DL")

        # Do we need to rename the file?
        if [ "$DEST_FILE" != 'dummy' ]; then
            log_debug 'Renaming file'

            PAGE=$(sockshare_curl_failsafe -b "$COOKIE_FILE" -L \
                -e "$BASE_URL/cp.php" \
                -d "edit_filename=$DEST_FILE" \
                -d "edit_alias=$FILE_ID" \
                -d "save_edit_file=Save Changes" \
                "$BASE_URL/cp.php?edit_file=$FILE_ID") || return

            RES_MESSAGE=$(echo "$PAGE" | parse_tag_quiet "class='message t_" div)

            if [ "$RES_MESSAGE" != 'File has been edited.' ]; then
                if [ -z "$RES_MESSAGE" ]; then
                    log_error 'Could not rename file.'
                else
                    log_error "Rename file error: $RES_MESSAGE"
                fi
                return $ERR_FATAL
            fi
        fi

        # Move file to selected folder
        if [ -n "$FOLDER" ]; then
            log_debug 'Moving file'

            PAGE=$(sockshare_curl_failsafe -b "$COOKIE_FILE" -L -G \
                -e "$BASE_URL/cp.php" \
                -d "file=$FILE_ID" \
                -d "moveto=$FOLDER_HASH" \
                "$BASE_URL/cp.php") || return

            RES_MESSAGE=$(echo "$PAGE" | parse_tag_quiet "class='message t_" div)

            if [ "$RES_MESSAGE" != 'File Moved' ]; then
                if [ -z "$RES_MESSAGE" ]; then
                    log_error 'Could not move file.'
                else
                    log_error "Move file error: $RES_MESSAGE"
                fi
                return $ERR_FATAL
            fi
        fi

    # Upload local file
    else
        local UP_SCRIPT UP_AUTH_HASH UP_SESSION UP_RESULT_ID UP_FOLDER_OPT

        PAGE=$(sockshare_curl_failsafe -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
            -e "$BASE_URL/index.php" \
            "$BASE_URL/upload_form.php") || return

        UP_SCRIPT=$(echo "$PAGE" | parse "'script'" ":[[:space:]]*'\([^']\+\)'") || return
        UP_AUTH_HASH=$(echo "$PAGE" | parse "'scriptData'" "'auth_hash'[[:space:]]*:[[:space:]]*'\([^']\+\)'") || return
        UP_SESSION=$(echo "$PAGE" | parse "'scriptData'" "'session'[[:space:]]*:[[:space:]]*'\([^']\+\)'") || return
        UP_RESULT_ID=$(echo "$PAGE" | parse 'upload_form.php?done=' "done=\([^']\+\)'") || return

        if [ -n "$FOLDER" ]; then
            UP_FOLDER_OPT="-F upload_folder=$FOLDER_ID"
        fi

        # No cookies needed, different domain (upload*.sockshare.com)
        PAGE=$(curl_with_log \
                -F "Filename=$DESTFILE" \
                $UP_FOLDER_OPT \
                -F "session=$UP_SESSION" \
                -F "folder=/" \
                -F "do_convert=1" \
                -F "auth_hash=$UP_AUTH_HASH" \
                -F "fileext=*" \
                -F "Filedata=@$FILE;filename=$DESTFILE" \
                -F "Upload=Submit Query" \
                "$UP_SCRIPT") || return

        if match 'Request could not be processed' "$PAGE"; then
            log_error 'Server cannot process the request, maybe due to overload.'
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        if [ "$PAGE" != 'cool story bro' ]; then
            log_error 'Unexpected response'
            return $ERR_FATAL
        fi

        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/cp.php?uploaded=$UP_RESULT_ID") || return

        LINK_DL=$(echo "$PAGE" | parse_attr "href=.$BASE_URL/file/" href) || return
        FILE_ID=$(parse . '^.*/\(.*\)$' <<< "$LINK_DL")
    fi

    # Set download password
    if [ -n "$LINK_PASSWORD" ]; then
        log_debug 'Setting password'

        PAGE=$(sockshare_curl_failsafe -b "$COOKIE_FILE" -L \
            -e "$BASE_URL/cp.php" \
            -d "file_password=$LINK_PASSWORD" \
            -d "file_id=$FILE_ID" \
            -d "make_private=Set Password" \
            "$BASE_URL/cp.php?private=$FILE_ID") || return

        RES_MESSAGE=$(echo "$PAGE" | parse_tag_quiet "class='message t_" div)

        if [ "$RES_MESSAGE" != 'Password set.' ]; then
            if [ -z "$RES_MESSAGE" ]; then
                log_error 'Could not set password.'
            else
                log_error "Set password error: $RES_MESSAGE"
            fi
            return $ERR_FATAL
        fi
    fi

    echo "$LINK_DL"
}

# Delete a file uploaded to sockshare.com
# $1: cookie file
# $2: sockshare (download) url
sockshare_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.sockshare.com'
    local PAGE FILE_ID RES_MESSAGE

    if ! match '/file/' "$URL"; then
        log_error 'Invalid URL format'
        return $ERR_BAD_COMMAND_LINE
    fi

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    FILE_ID=$(parse . '^.*/\(.*\)$' <<< "$URL")

    sockshare_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(sockshare_curl_failsafe -b "$COOKIE_FILE" -L -G \
        -e "$BASE_URL/cp.php" \
        -d "delete=$FILE_ID" \
        "$BASE_URL/cp.php") || return

    RES_MESSAGE=$(echo "$PAGE" | parse_tag_quiet "class='message t_" div)

    # Site always returns 'File Deleted' even if already deleted
    if [ "$RES_MESSAGE" != 'File Deleted' ]; then
        if [ -z "$RES_MESSAGE" ]; then
            log_error 'Could not delete file.'
        else
            log_error "Delete file error: $RES_MESSAGE"
        fi
        return $ERR_FATAL
    fi
}

# List a sockshare.com folder
# $1: sockshare.com folder link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
sockshare_list() {
    local -r URL=$1
    local -r BASE_URL='http://www.sockshare.com'
    local RET=0
    local PAGE LOCATION NAMES LINKS FOLDER_HASH LAST_PAGE PAGE_NUMBER

    if ! match '/public/' "$URL"; then
        log_error 'Invalid URL format'
        return $ERR_BAD_COMMAND_LINE
    fi

    PAGE=$(sockshare_curl_failsafe -i "$URL") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)

    [ -n "$LOCATION" ] && return $ERR_LINK_DEAD

    FOLDER_HASH=$(parse . '^.*/\(.*\)$' <<< "$URL")

    LAST_PAGE=$(echo "$PAGE" | parse_all_quiet "folder_pub=" 'page=\([0-9]\+\)' | last_line)

    PAGE=$(echo "$PAGE" | parse_all_quiet "<a href=\"$BASE_URL/file/" '\(<a href=.*</a>\)')
    [ -z "$PAGE" ] && return $ERR_LINK_DEAD

    # Generic pattern to parse both streaming and non streaming folder content
    # Streaming: <a href="file_URL"><img src="thumb_URL"><br>file_name</a>
    # Binary: <a href="file_URL">file_name</a>
    NAMES=$(echo "$PAGE" | parse_all . '>\([^<]\+\)<')
    LINKS=$(echo "$PAGE" | parse_all_attr href)

    if [ -n "$LAST_PAGE" ]; then
        for (( PAGE_NUMBER=2; PAGE_NUMBER<=LAST_PAGE; PAGE_NUMBER++ )); do
            log_debug "Listing page #$PAGE_NUMBER"

            PAGE=$(sockshare_curl_failsafe -G \
                -d "folder_pub=$FOLDER_HASH" \
                -d "page=$PAGE_NUMBER" \
                "$URL") || return

            PAGE=$(echo "$PAGE" | parse_all_quiet "<a href=\"$BASE_URL/file/" '\(<a href=.*</a>\)')

            NAMES=$NAMES$'\n'$(echo "$PAGE" | parse_all . '>\([^<]\+\)<')
            LINKS=$LINKS$'\n'$(echo "$PAGE" | parse_all_attr href)
        done
    fi

    list_submit "$LINKS" "$NAMES" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: sockshare.com url
# $3: requested capability list
# stdout: 1 capability per line
sockshare_probe() {
    local -r URL=${2/\/embed\//\/file\/}
    local -r REQ_IN=$3
    local PAGE LOCATION FILE_NAME FILE_SIZE REQ_OUT

    if ! match '/file/' "$URL"; then
        log_error 'Invalid URL format'
        return $ERR_BAD_COMMAND_LINE
    fi

    PAGE=$(sockshare_curl_failsafe -i "$URL") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)

    if [ "$LOCATION" = '../?404' ]; then
        return $ERR_LINK_DEAD
    elif [ -n "$LOCATION" ]; then
        log_error 'Unknown error'
        return $ERR_FATAL
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '<h1>' '<h1>\([^<]\+\)' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '<h1>' '<strong>( \(.\+\) )' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
