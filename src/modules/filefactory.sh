# Plowshare filefactory.com module
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

MODULE_FILEFACTORY_REGEXP_URL='http://\(www\.\)\?filefactory\.com/'

MODULE_FILEFACTORY_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_FILEFACTORY_DOWNLOAD_RESUME=no
MODULE_FILEFACTORY_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FILEFACTORY_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FILEFACTORY_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
FOLDER,,folder,s=FOLDER,Folder to upload files into
ASYNC,,async,,Asynchronous remote upload (only start upload, don't wait for link)
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_FILEFACTORY_UPLOAD_REMOTE_SUPPORT=yes

MODULE_FILEFACTORY_LIST_OPTIONS=""
MODULE_FILEFACTORY_LIST_HAS_SUBFOLDERS=no

MODULE_FILEFACTORY_PROBE_OPTIONS=""

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
filefactory_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT LOCATION

    LOGIN_DATA='loginEmail=$USER&loginPassword=$PASSWORD&Submit=Sign In'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/member/signin.php" -i) || return

    LOCATION=$(grep_http_header_location_quiet <<< "$LOGIN_RESULT")

    if [ "$LOCATION" != '/account/' ]; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a filefactory.com file download URL
# $1: cookie file
# $2: filefactory.com url
# stdout: real file download link
filefactory_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(replace '://filefactory' '://www.filefactory' <<< "$2")
    local -r BASE_URL='http://www.filefactory.com'
    local PAGE LOCATION WAIT_TIME FILE_URL

    if [ -n "$AUTH" ]; then
        filefactory_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    if [ -n "$LOCATION" ]; then
        if match '/error\.php?code=25[14]' "$LOCATION"; then
            return $ERR_LINK_DEAD
        elif match '/error\.php?code=258' "$LOCATION"; then
            return $ERR_LINK_NEED_PERMISSIONS
        elif match '/error\.php?code=' "$LOCATION"; then
            log_error "Remote error code: '${LOCATION:16}'"
            return $ERR_FATAL
        elif match '/preview/' "$LOCATION"; then
            PAGE=$(curl -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return
        fi
    fi

    if match 'Please enter the password' "$PAGE"; then
        log_debug 'File is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return

            PAGE=$(curl -b "$COOKIE_FILE" -L \
                -d "password=$LINK_PASSWORD" \
                -d 'Submit=Continue' \
                "$URL") || return

            if match 'The Password entered was incorrect' "$PAGE"; then
                return $ERR_LINK_PASSWORD_REQUIRED
            fi
        fi
    fi

    # If this an image ?
    if match '[[:space:]]id=.image_main.[[:space:]]' "$PAGE"; then
        FILE_URL=$(parse_attr 'Download Image' 'href' <<< "$PAGE") || return
    else
        WAIT_TIME=$(parse_attr 'data-delay' <<< "$PAGE") || return
        wait $WAIT_TIME || return

        FILE_URL=$(parse_attr 'data-href' <<< "$PAGE") || return
    fi

    # Redirect to /?code=275 on simultaneous download for non-premium, 1hr download limit
    echo $FILE_URL
}

# Upload a file to filefactory.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
filefactory_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.filefactory.com'
    local -r MAX_SIZE=2097152000 # 2000 MiB

    local PAGE AUTH_COOKIE FOLDERS FOLDER_HASH FILE_CODE

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    if ! match_remote_url "$FILE"; then
        local FILE_SIZE=$(get_filesize "$FILE")
        if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
            log_debug "File is bigger than $MAX_SIZE"
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    filefactory_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

    AUTH_COOKIE=$(parse_cookie 'auth' < "$COOKIE_FILE") || return
    AUTH_COOKIE=$(uri_decode <<< "$AUTH_COOKIE") || return

    if [ -n "$FOLDER" ]; then
        log_debug 'Getting folder data...'

        PAGE=$(curl -b "$COOKIE_FILE" -G \
            -d 'm=getFolders' \
            "$BASE_URL/manager2/get.php") || return

        FOLDERS=$(parse_json 'title' 'split' <<< "$PAGE") || return
        FOLDERS=$(delete_first_line <<< "$FOLDERS")

        if ! match "^$FOLDER$" "$FOLDERS"; then
            log_debug "Creating folder '$FOLDER'..."

            PAGE=$(curl -b "$COOKIE_FILE" \
                -H 'X-Requested-With: XMLHttpRequest' \
                -d 'func=createFolder' \
                -d "name=$FOLDER" \
                "$BASE_URL/upload/ajax.php") || return

            if ! match 'Your folder was created successfully' "$PAGE"; then
                log_error 'Could not create folder'
            else
                FOLDER_HASH=$(parse_json 'hash' <<< "$PAGE") || return
            fi
        else
            PAGE=$(replace ',"icon"' $',"icon"\n' <<< "$PAGE")
            FOLDER_HASH=$(parse "\"title\":\"$FOLDER\"" '"id":"\([^"]\+\)' <<< "$PAGE") || return
        fi

        log_debug "Folder hash: '$FOLDER_HASH'"
    fi

    # Upload remote file
    if match_remote_url "$FILE"; then
        local TRY FILE_STATE LINK_DL

        if ! match '^https\?://' "$FILE" && ! match '^ftp://' "$FILE"; then
            log_error 'Unsupported protocol for remote upload.'
            return $ERR_BAD_COMMAND_LINE
        fi

        if [ -z "$FOLDER" ]; then
            FOLDER_HASH="0"
        fi

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d 'remoteUsername=' \
            -d 'remotePassword=' \
            -d "folder_name=$FOLDER_HASH" \
            -d "remoteList=$FILE" \
            -d 'Submit=Upload Files' \
            "$BASE_URL/upload/remote.php") || return

        if ! match 'The submitted link was successfully added to the remote queue.' "$PAGE"; then
            log_error 'Could not set remote upload.'
            return $ERR_FATAL
        fi

        # If this is an async upload, we are done
        if [ -n "$ASYNC" ]; then
            log_error 'Once remote upload completed, check your account for link.'
            return $ERR_ASYNC_REQUEST
        fi

        TRY=1
        while [ "$FILE_STATE" != 'Complete' ]; do
            PAGE=$(curl -b "$COOKIE_FILE" \
                -H 'X-Requested-With: XMLHttpRequest' \
                "$BASE_URL/upload/status/modal.php?type=remote") || return

            FILE_STATE=$(parse_attr 'data-sort-value' <<< "$PAGE") || return

            [ "$FILE_STATE" = 'Complete' ] && break

            if [ "$FILE_STATE" != 'Saving' ] && \
                [ "$FILE_STATE" != 'Downloading' ] && \
                [ "$FILE_STATE" != 'Pending' ]; then
                [ "$FILE_STATE" = 'Failed' ] && log_error 'Upload failed.'
                [ "$FILE_STATE" != 'Failed' ] && log_error "Upload failed. Unknown state: '$FILE_STATE'."
                return $ERR_FATAL
            fi

            log_debug "Wait for server to download the file... [$((TRY++))]"
            wait 15 || return
        done

        LINK_DL=$(parse_attr 'Download</a>' 'href' <<< "$PAGE") || return
        FILE_CODE=$(parse . '^.*/\([^/]\+\)/$' <<< "$LINK_DL") || return

        # Do we need to rename the file?
        if [ "$DEST_FILE" != 'dummy' ]; then
            log_debug 'Renaming file...'

            PAGE=$(curl -b "$COOKIE_FILE" \
                -d 'm=editFile' \
                -d "h=$FILE_CODE" \
                -d "filename=$DEST_FILE" \
                -d 'description=' \
                "$BASE_URL/manager2/set.php") || return

            if [ "$PAGE" != '{"status":"ok"}' ]; then
                log_error 'Could not rename file.'
            fi
        fi

    # Upload local file
    else
        PAGE=$(curl_with_log \
            -F "cookie=$AUTH_COOKIE" \
            -F "Filedata=@$FILE;filename=$DEST_FILE" \
            'http://upload.filefactory.com/upload-beta.php') || return

        if ! match '^[[:alnum:]]\+$' "$PAGE"; then
            log_error 'Upload failed.'
            return $ERR_FATAL
        else
            FILE_CODE="$PAGE"
        fi

        if [ -n "$FOLDER" ]; then
            log_debug "Moving file to folder '$FOLDER'..."

            PAGE=$(curl -b "$COOKIE_FILE" \
                -H 'X-Requested-With: XMLHttpRequest' \
                -d 'func=moveFiles' \
                -d "folder=$FOLDER_HASH" \
                -d "files=$FILE_CODE" \
                "$BASE_URL/upload/ajax.php") || return

            if ! match 'The selected files were moved successfully' "$PAGE"; then
                log_error 'Could not move file into folder.'
            fi
        fi
    fi

    if [ -n "$LINK_PASSWORD" ]; then
        log_debug 'Setting download password...'

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "m=setPassword" \
            -d "p=$LINK_PASSWORD" \
            -d "fi=$FILE_CODE" \
            "$BASE_URL/manager2/set.php") || return

        if [ "$PAGE" != '{"status":"ok","password":"yes"}' ]; then
            log_error 'Could not set password.'
        fi
    fi

    if [ -n "$TOEMAIL" ]; then
        log_debug 'Sending link...'

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d 'm=emailFile' \
            -d "h=$FILE_CODE" \
            -d "r=$TOEMAIL" \
            -d 'message=' \
            "$BASE_URL/manager2/set.php") || return

        if [ "$PAGE" != '{"status":"ok"}' ]; then
            log_error 'Could not send link.'
        fi
    fi

    echo "$BASE_URL/file/$FILE_CODE/"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: filefactory.com url
# $3: requested capability list
# stdout: 1 capability per line
filefactory_probe() {
    local -r URL=$(replace '://filefactory' '://www.filefactory' <<< "$2")
    local -r REQ_IN=$3
    local PAGE LOCATION FILE_SIZE REQ_OUT

    PAGE=$(curl -i "$URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    if match '/error.php?code=251' "$LOCATION" || \
        match '/error.php?code=254' "$LOCATION"; then
        return $ERR_LINK_DEAD

    elif match '/error.php?code=' "$LOCATION"; then
        log_error "Remote error code: '${LOCATION:16}'"
        return $ERR_FATAL
    fi

    REQ_OUT=c

    # All data is hidden for password protected files
    if match 'Please enter the password' "$PAGE"; then
        return $REQ_OUT
    fi

    if [[ $REQ_IN = *f* ]]; then
        parse 'file_name' \
        '<h2>\([^<]\+\)' 1 <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'file_info' \
        '<div id="file_info">\(.*\) uploaded' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a filefactory.com web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
filefactory_list() {
    local -r URL=$(replace '://filefactory.com' '://www.filefactory' <<< "$1")
    local -r REC=$2
    local PAGE LOCATION LINKS NAMES

    PAGE=$(curl -i -G \
        -d 'export=1' \
        "$URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    if match '/error.php?code=300' "$LOCATION"; then
        return $ERR_LINK_DEAD

    elif match '/error.php?code=' "$LOCATION"; then
        log_error "Remote error code: '${LOCATION:16}'"
        return $ERR_FATAL
    fi

    NAMES=$(parse_all_quiet . '^\"\([^"]\+\)' <<< "$PAGE")
    LINKS=$(parse_all_quiet . '[^"],"\([^"]\+\)' <<< "$PAGE")

    list_submit "$LINKS" "$NAMES"
}
