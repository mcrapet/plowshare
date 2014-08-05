# Plowshare myvdrive.com module
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

MODULE_MYVDRIVE_REGEXP_URL='http://\(www\.\)\?myvdrive\.com/'

MODULE_MYVDRIVE_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_MYVDRIVE_DOWNLOAD_RESUME=yes
MODULE_MYVDRIVE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_MYVDRIVE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_MYVDRIVE_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
FOLDER,,folder,s=FOLDER,Folder to upload files into
ASYNC,,async,,Asynchronous remote upload (only start upload, don't wait for link)
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email
PRIVATE_FILE,,private,,Mark file for personal use only"
MODULE_MYVDRIVE_UPLOAD_REMOTE_SUPPORT=yes

MODULE_MYVDRIVE_LIST_OPTIONS=""
MODULE_MYVDRIVE_LIST_HAS_SUBFOLDERS=yes

MODULE_MYVDRIVE_PROBE_OPTIONS=""

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
myvdrive_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local PAGE LOGIN_DATA LOGIN_RESULT LOCATION
    local FORM_HTML FORM_ACTION FORM_DPT_ID FORM_DPT FORM_FAI_CAL FORM_SUC_CAL FORM_SIG FORM_HASH

    PAGE=$(curl "$BASE_URL/Public/login") || return

    FORM_HTML=$(grep_form_by_name "$PAGE" 'login_form') || return
    FORM_ACTION=$(parse_form_action "$FORM_HTML" <<< "$FORM_HTML") || return
    FORM_DPT_ID=$(parse_form_input_by_name 'dpt_id' <<< "$FORM_HTML") || return
    FORM_DPT=$(parse_form_input_by_name 'from_dpt' <<< "$FORM_HTML") || return
    FORM_FAI_CAL=$(parse_form_input_by_name 'fail_callback' <<< "$FORM_HTML") || return
    FORM_SUC_CAL=$(parse_form_input_by_name 'success_callback' <<< "$FORM_HTML") || return
    FORM_SIG=$(parse_form_input_by_name 'signup' <<< "$FORM_HTML") || return
    FORM_HASH=$(parse_form_input_by_name '__hash__' <<< "$FORM_HTML") || return

    LOGIN_DATA="username=\$USER&password=\$PASSWORD&dpt_id=$FORM_DPT_ID&from_dpt=$FORM_DPT&fail_callback=$FORM_FAI_CAL&success_callback=$FORM_SUC_CAL&signup=$FORM_SIG&__hash__=$FORM_HASH"
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$FORM_ACTION" -L) || return

    if ! match 'http://www.myvdrive.com/My/index' "$LOGIN_RESULT"; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a myvdrive.com file download URL
# $1: cookie file
# $2: myvdrive.com url
# stdout: real file download link
myvdrive_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(replace '://myvdrive' '://www.myvdrive' <<< "$2")
    local -r BASE_URL='http://www.myvdrive.com'

    local PAGE LOCATION FILE_CODE FILENAME FILE_URL FORM_HASH

    FILE_CODE=$(parse . '/files/\([^/]\+\)' <<< "$URL") || return

    if [ -n "$AUTH" ]; then
        myvdrive_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    # User files download immediately, maybe like premium
    if match '/download/' "$LOCATION"; then
        PAGE=$(curl -b "$COOKIE_FILE" -L -I --max-redirs 1 "$LOCATION") || return
        FILE_URL=$(grep_http_header_location <<< "$PAGE") || return
        FILE_URL=$(last_line <<< "$FILE_URL")

        # Session dies after first request, maybe different for premium
        #PAGE=$(curl -b "$COOKIE_FILE" -I "$FILE_URL") || return
        #FILENAME=$(grep_http_header_content_disposition <<< "$PAGE") || return

        FILENAME=$(basename_file "$URL")

        echo "$FILE_URL"
        echo "$FILENAME"
        return 0

    elif match '/Index/password/' "$LOCATION"; then
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL$LOCATION") || return

    elif [ -n "$LOCATION" ]; then
        log_error "Unexpected redirect location: '$LOCATION'"
        return $ERR_FATAL
    fi

    if match 'Sorry, this file has been removed' "$PAGE"; then
        return $ERR_LINK_DEAD

    elif match 'This is a private file!' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    if match 'Please enter the correct password in order to download this file.' "$PAGE"; then
        log_debug 'File is password protected'

        FORM_HASH=$(parse_form_input_by_name '__hash__' <<< "$PAGE") || return

        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return

            PAGE=$(curl -b "$COOKIE_FILE" -L \
                -d "password=$LINK_PASSWORD" \
                -d 'submit=Submit' \
                -d "__hash__=$FORM_HASH" \
                "$BASE_URL$LOCATION") || return

            if match 'Password Incorrect! Please Try Again.' "$PAGE"; then
                return $ERR_LINK_PASSWORD_REQUIRED
            fi
        fi
    fi

    FILENAME=$(parse 'dl_name' '^[[:space:]]*\([^<]\+\)' 1 <<< "$PAGE") || return
    FILENAME=$(strip <<< "$FILENAME")

    PAGE=$(curl -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest' \
        "$BASE_URL/Index/verifyRecaptcha?fid=$FILE_CODE&sscode=&v=&server=") || return

    PAGE=$(parse_json 'html' <<< "$PAGE") || return

    FILE_URL=$(parse_attr 'Your download is ready' 'href' <<< "$PAGE") || return

    if match '/download/' "$FILE_URL"; then
        PAGE=$(curl -b "$COOKIE_FILE" -L -I --max-redirs 1 "$FILE_URL") || return
        FILE_URL=$(grep_http_header_location <<< "$PAGE") || return
        FILE_URL=$(last_line <<< "$FILE_URL")
    fi

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Check if specified folder name is valid.
# There cannot be two folders with the same name in root.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base URL
# stdout: folder ID
myvdrive_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local PAGE FOLDERS FOLDER_ID

    log_debug "Getting folder ID..."

    PAGE=$(curl -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d 'dir=/' \
        "$BASE_URL/Myfile/getFolderTree") || return
    PAGE=$(break_html_lines <<< "$PAGE")

    FOLDERS=$(parse_all_tag 'selectFolder' 'a' <<< "$PAGE") || return
    FOLDERS=$(delete_first_line 2 <<< "$FOLDERS")

    if ! match "^$NAME$" "$FOLDERS"; then
        log_debug "Creating folder '$NAME'..."

        PAGE=$(curl -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d 'parent_id=0' \
            -d "name=$NAME" \
            "$BASE_URL/Myfile/addSubFolder") || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d 'dir=/' \
            "$BASE_URL/Myfile/getFolderTree") || return
        PAGE=$(break_html_lines <<< "$PAGE")

        FOLDERS=$(parse_all_tag_quiet 'selectFolder' 'a' <<< "$PAGE")
        FOLDERS=$(delete_first_line 2 <<< "$FOLDERS")

        if ! match "^$NAME$" "$FOLDERS"; then
            log_error 'Could not create folder.'
            return $ERR_FATAL
        fi
    fi

    FOLDER_ID=$(parse "selectFolder([0-9]\+,'$NAME')" 'selectFolder(\([0-9]\+\)' <<< "$PAGE") || return

    log_debug "Folder ID: '$FOLDER_ID'"

    echo "$FOLDER_ID"
}

# Upload a file to myvdrive.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
myvdrive_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.myvdrive.com'

    local PAGE FILE_CODE FILENAME FOLDER_ID

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    if [ -n "$PRIVATE_FILE" ] && [ -n "$LINK_PASSWORD" ]; then
        log_error 'Impossible to set password and private flag at the same time.'
        return $ERR_BAD_COMMAND_LINE
    fi

    myvdrive_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(myvdrive_check_folder "$FOLDER" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Upload remote file
    if match_remote_url "$FILE"; then
        local TRY FORM_HASH UP_ID UP_STATUS UP_UPDATE

        if ! match '^https\?://' "$FILE" && ! match '^ftp://' "$FILE"; then
            log_error 'Unsupported protocol for remote upload.'
            return $ERR_BAD_COMMAND_LINE
        fi

        PAGE=$(curl -b "$COOKIE_FILE" \
            "$BASE_URL/Index/remote") || return

        FORM_HASH=$(parse_form_input_by_name '__hash__' <<< "$PAGE") || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "links=$FILE" \
            -d 'term=on' \
            -d 'submit=Upload Files' \
            -d "__hash__=$FORM_HASH" \
            "$BASE_URL/Index/remote") || return

        UP_ID=$(parse_form_input_by_name 'checkbox\[\]' <<< "$PAGE") || return
        UP_STATUS=$(parse_form_input_by_name 'link_status' <<< "$PAGE") || return

        # If this is an async upload, we are done
        if [ -n "$ASYNC" ]; then
            log_error 'Once remote upload completed, check your account for link.'
            return $ERR_ASYNC_REQUEST
        fi

        TRY=1
        # Upload states
        # 0 = pending
        # 1 = processing
        # 2 = completed
        while [ "$UP_STATUS" != '2' ]; do
            PAGE=$(curl -b "$COOKIE_FILE" -G \
                -H 'X-Requested-With: XMLHttpRequest' \
                -d 'act=update' \
                -d "ids=$UP_ID" \
                -d "statuses=$UP_STATUS" \
                "$BASE_URL/Index/ajax_remote_status/") || return

            UP_UPDATE=$(parse_quiet . '"change_status":\[\[\(.*\)\]\]' <<< "$PAGE")
            if match "\"$UP_ID\"" "$UP_UPDATE"; then
                UP_STATUS=$(parse . "\"$UP_ID\",\"\([0-9]\+\)\"" <<< "$UP_UPDATE") || return
            fi

            [ "$UP_STATUS" = '2' ] && break

            if [ "$UP_STATUS" != '1' ] && [ "$UP_STATUS" != '0' ]; then
                log_error "Upload failed. Unknown status: '$UP_STATUS'."
                return $ERR_FATAL
            fi

            log_debug "Wait for server to download the file... [$((TRY++))]"
            wait 10 || return
        done

        PAGE=$(curl -b "$COOKIE_FILE" \
            "$BASE_URL/Index/remote") || return

        FILE_CODE=$(parse "<input[^>]*name=\"checkbox\[\]\" value=\"$UP_ID\"" \
            'href="http://www\.myvdrive\.com/files/\([^"]\+\)' 3 <<< "$PAGE") || return

    # Upload local file
    else
        local UP_HASH UP_URL UP_RESULT
        local FILE_SIZE=$(get_filesize "$FILE")

        PAGE=$(curl -b "$COOKIE_FILE" \
            "$BASE_URL/My/upload?fpath=$FOLDER") || return

        UP_HASH=$(parse 'fsUploader.multiHash' \
            "fsUploader.multiHash = '\([^']\+\)" <<< "$PAGE") || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -e "$BASE_URL/My/upload?fpath=$FOLDER" \
            "$BASE_URL/Index/getUserLimit/type/json") || return

        MAX_SIZE=$(parse_json 'upload_limit' <<< "$PAGE") || return
        UP_URL=$(parse_json 'upload_url' <<< "$PAGE") || return

        if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
            log_debug "File is bigger than $MAX_SIZE"
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi

        PAGE=$(curl_with_log \
            -F "Filedata=@$FILE;filename=$DEST_FILE" \
            "$UP_URL&multihash=$UP_HASH") || return

        UP_RESULT=$(parse_json 'result' <<< "$PAGE") || return

        if [ "$UP_RESULT" != 'successful' ]; then
            log_error "Upload failed. Result: '$UP_RESULT'."
            return $ERR_FATAL
        fi

        FILE_CODE=$(parse_json 'link_id' <<< "$PAGE") || return
        FILENAME=$(parse_json 'file_name' <<< "$PAGE") || return
    fi

    if [ -z "$FILENAME" ] || [ -n "$LINK_PASSWORD" ] || \
        [ -n "$PRIVATE_FILE" ] || [ -n "$TOEMAIL" ]; then
        local FILE_ID FOLDER_ID_SRC

        # Remote uploads appear in root
        if match_remote_url "$FILE" || [ -z "$FOLDER_ID" ]; then
            FOLDER_ID_SRC='0'
        else
            FOLDER_ID_SRC="$FOLDER_ID"
        fi

        PAGE=$(curl -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d "folder_id=$FOLDER_ID_SRC" \
            -d 'sortby=fileid' \
            -d 'sort=desc' \
            -d 'page=1' \
            "$BASE_URL/Myfile/getFolderFiles") || return
        PAGE=$(replace_all '},' $'},\n' <<< "$PAGE")

        FILE_ID=$(parse "\"linkid\":\"$FILE_CODE\"" '"fileid":"\([0-9]\+\)"' <<< "$PAGE") || return

        # Remote upload specific routines
        #  Get filename / Rename file
        #  Move to folder
        if match_remote_url "$FILE"; then
            if [ "$DEST_FILE" != 'dummy' ]; then
                local FILENAME_EXT FILENAME_NAM

                log_debug 'Renaming file...'

                FILENAME="$DEST_FILE"

                FILENAME_EXT="${FILENAME##*.}"
                FILENAME_NAM="${FILENAME%.*}"

                # Description doesen't appear anywhere
                PAGE=$(curl -b "$COOKIE_FILE" \
                    -H 'X-Requested-With: XMLHttpRequest' \
                    -d "file_id=f_$FILE_ID" \
                    -d "file_name=$FILENAME_NAM" \
                    -d 'file_desc=' \
                    -d "file_name_ext=$FILENAME_EXT" \
                    -d 'file_check=no' \
                    "$BASE_URL/Myfile/updateFileByUploadId") || return

                if [ "$PAGE" != '1' ]; then
                    log_error 'Could not rename file.'
                fi
            else
                FILENAME=$(parse '"fileid":"[0-9]\+"' '"filename":"\([^"]\+\)' <<< "$PAGE") || return
            fi

            if [ -n "$FOLDER" ]; then
                log_debug 'Moving file to folder...'

                PAGE=$(curl -b "$COOKIE_FILE" \
                    -H 'X-Requested-With: XMLHttpRequest' \
                    -d "folder_id=f_d99$FOLDER_ID" \
                    -d "files[]=f_$FILE_ID" \
                    "$BASE_URL/Myfile/moveFiles") || return

                if [ "$PAGE" != '1' ]; then
                    if match 'The File name .* already exists' "$PAGE"; then
                        log_error 'Could not move file into folder. File with the same name exists in selected folder.'
                    else
                        log_error 'Could not move file into folder.'
                    fi
                fi
            fi
        fi

        if [ -n "$LINK_PASSWORD" ] || [ -n "$PRIVATE_FILE" ]; then
            log_debug 'Editing file settings...'

            [ -z "$PRIVATE_FILE" ] && PRIVATE_FILE=0

            PAGE=$(curl -b "$COOKIE_FILE" \
                -H 'X-Requested-With: XMLHttpRequest' \
                -d "private_type=$PRIVATE_FILE" \
                -d "password=$LINK_PASSWORD" \
                -d "files[]=f_$FILE_ID" \
                "$BASE_URL/Myfile/privateSetting") || return

            if [ "$PAGE" != '1' ]; then
                log_error 'Could not edit file settings.'
            fi
        fi

        if [ -n "$TOEMAIL" ]; then
            log_debug 'Sending link...'

            PAGE=$(curl -b "$COOKIE_FILE" \
                -H 'X-Requested-With: XMLHttpRequest' \
                -d "file_id=f_$FILE_ID" \
                -d "link_id=$FILE_CODE" \
                -d "email=$TOEMAIL" \
                -d 'message=Check out my file on Fileserving' \
                "$BASE_URL/Myfile/share") || return

            if [ "$PAGE" != '1' ]; then
                log_error 'Could not send link.'
            fi
        fi
    fi

    echo "$BASE_URL/files/$FILE_CODE/$FILENAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: myvdrive.com url
# $3: requested capability list
# stdout: 1 capability per line
myvdrive_probe() {
    local -r URL=$(replace '://myvdrive' '://www.myvdrive' <<< "$2")
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl \
        -d "links=$URL" \
        'http://www.myvdrive.com/Public/linkchecker') || return

    if match 'check_notvalid' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match 'check_valid' "$PAGE"; then
        REQ_OUT=c
    else
        return $ERR_FATAL
    fi

    if [[ $REQ_IN = *f* ]]; then
        parse 'check_valid' \
        '^[[:space:]]*\([^\t]\+\)' 3 <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'check_valid' \
        '^[[:space:]]*\([^\t]\+\)' 5 <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a myvdrive.com web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
myvdrive_list() {
    local -r URL=$(replace '://myvdrive' '://www.myvdrive' <<< "$1")
    local -r REC=$2
    local PAGE LINKS NAMES

    PAGE=$(curl "$URL") || return

    LINKS=$(parse_all_attr_quiet '^[[:space:]]*<span class="item_name_text">.*/files/' 'href' <<< "$PAGE")
    NAMES=$(parse_all_tag_quiet '^[[:space:]]*<span class="item_name_text">.*/files/' 'a' <<< "$PAGE")

    list_submit "$LINKS" "$NAMES"

    if [ -n "$REC" ]; then
        local FOLDERS FOLDER

        FOLDERS=$(parse_all_attr_quiet '^[[:space:]]*<span class="item_name_text">.*/Public/folder/' 'href' <<< "$PAGE")
        # First folder is always '..'
        FOLDERS=$(delete_first_line <<< "$FOLDERS")

        while read FOLDER; do
            [ -z "$FOLDER" ] && continue
            log_debug "Entering sub folder: $FOLDER"
            myvdrive_list "$FOLDER" "$REC" && RET=0
        done <<< "$FOLDERS"
    fi
}
