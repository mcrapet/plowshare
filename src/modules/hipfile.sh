# Plowshare hipfile.com module
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

MODULE_HIPFILE_REGEXP_URL='http://\(www\.\)\?hipfile\.com/[[:alnum:]]\+'

MODULE_HIPFILE_DOWNLOAD_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_HIPFILE_DOWNLOAD_RESUME=yes
MODULE_HIPFILE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_HIPFILE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_HIPFILE_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
FOLDER,,folder,s=FOLDER,Folder to upload files into
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email
PREMIUM,,premium,,Make file inaccessible to non-premium users
PRIVATE_FILE,,private,,Do not make file visible in folder view"
MODULE_HIPFILE_UPLOAD_REMOTE_SUPPORT=no

MODULE_HIPFILE_LIST_OPTIONS=""
MODULE_HIPFILE_LIST_HAS_SUBFOLDERS=yes

MODULE_HIPFILE_DELETE_OPTIONS=""
MODULE_HIPFILE_PROBE_OPTIONS=""

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
hipfile_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT STATUS NAME

    LOGIN_DATA='op=login&login=$USER&password=$PASSWORD&redirect='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA$BASE_URL/?op=my_account" \
        "$BASE_URL" -L -b 'lang=english') || return

    # If successful, two entries are added into cookie file: login and xfss
    STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
    if [ -z "$STATUS" ]; then
        return $ERR_LOGIN_FAILED
    fi

    NAME=$(parse_cookie 'login' < "$COOKIE_FILE")
    log_debug "Successfully logged in as $NAME member"
}

# Check if account has enough space to upload file
# $1: upload file size
# $2: cookie file (logged into account)
# $3: base URL
hipfile_check_freespace() {
    local -r FILE_SIZE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local PAGE SPACE_USED SPACE_LIMIT

    PAGE=$(curl -b 'lang=english' -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL") || return

    # XXX Kb of XXX GB
    SPACE_USED=$(echo "$PAGE" | parse 'Used space' \
        ' \([0-9.]\+[[:space:]]*[KMGBb]\+\) of ') || return
    SPACE_USED=$(translate_size "$(uppercase "$SPACE_USED")")

    SPACE_LIMIT=$(echo "$PAGE" | parse 'Used space' \
        'of \([0-9.]\+[[:space:]]*[KMGBb]\+\)') || return
    SPACE_LIMIT=$(translate_size "$(uppercase "$SPACE_LIMIT")")

    log_debug "Space: $SPACE_USED / $SPACE_LIMIT"

    # Check space limit
    if (( ( "$SPACE_LIMIT" - "$SPACE_USED" ) < "$FILE_SIZE" )); then
        log_error 'Not enough space in account folder.'
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi
}

# Check if specified folder name is valid.
# When multiple folders wear the same name, first one is taken.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base URL
# stdout: folder ID
hipfile_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local PAGE FORM FOLDERS FOL FOL_ID

    # Special treatment for root folder (always uses ID "0")
    if [ "$NAME" = '/' ]; then
        echo 0
        return 0
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL") || return
    FORM=$(grep_form_by_name "$PAGE" 'F1') || return

    # <option value="ID">&nbsp;NAME</option>
    # Note: - Site uses "&nbsp;" to indent sub folders
    #       - First entry is label "Move files to folder"
    #       - Second entry is root folder "/"
    FOLDERS=$(echo "$FORM" | parse_all_tag option | delete_first_line 2 |
        replace_all '&nbsp;' '') || return

    if ! match "^$NAME$" "$FOLDERS"; then
        log_debug 'Creating folder.'
        PAGE=$(curl -b "$COOKIE_FILE" -L \
            -d 'op=my_files' \
            -d 'fld_id=0' \
            -d "create_new_folder=$NAME" \
            "$BASE_URL") || return

        FORM=$(grep_form_by_name "$PAGE" 'F1') || return

        FOLDERS=$(echo "$FORM" | parse_all_tag option | delete_first_line 2 |
            replace_all '&nbsp;' '') || return
        if [ -z "$FOLDERS" ]; then
            log_error 'No folder found. Site updated?'
            return $ERR_FATAL
        fi

        if ! match "^$NAME$" "$FOLDERS"; then
            log_error "Could not create folder"
            return $ERR_FATAL
        fi
    fi

    FOL_ID=$(echo "$FORM" | parse_attr "<option.*$NAME</option>" 'value')
    if [ -z "$FOL_ID" ]; then
        log_error "Could not get folder ID."
        return $ERR_FATAL
    fi

    echo "$FOL_ID"
}

# Output a hipfile.com file download URL
# $1: cookie file
# $2: hipfile.com url
# stdout: real file download link
hipfile_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://hipfile.com'
    local PAGE WAIT_TIME FILE_URL ERROR

    PAGE=$(curl -c "$COOKIE_FILE" -b 'lang=english' -b "$COOKIE_FILE" "$URL") || return

    if match 'File Not Found\|file was removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi


    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_REFERER FORM_RAND FORM_METHOD_F
    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname') || return
    FORM_REFERER=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'referer')
    FORM_METHOD_F=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -d "op=$FORM_OP" \
        -d "usr_login=$FORM_USR" \
        -d "id=$FORM_ID" \
        --data-urlencode "fname=$FORM_FNAME" \
        -d "referer=$FORM_REFERER" \
        -d "method_free=$FORM_METHOD_F" "$URL") || return

    if match 'This file is available for Premium Users only' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand') || return
    FORM_REFERER=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'referer')
    FORM_METHOD_F=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')

    WAIT_TIME=$(echo "$PAGE" | parse_tag_quiet 'countdown_str' 'span')
    # Wait some more to avoid "Skipped countdown" error
    WAIT_TIME=$((WAIT_TIME + 1))

    if match '"password"' "$FORM_HTML"; then
        log_debug 'File is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            # If password is too long :)
            local TIME
            TIME=$(date +%s)
            LINK_PASSWORD=$(prompt_for_password) || return
            TIME=$(($(date +%s) - $TIME))
            if [ $TIME -lt $WAIT_TIME ]; then
                WAIT_TIME=$((WAIT_TIME - $TIME))
            else
                unset WAIT_TIME
            fi
        fi
    fi

    if [ -n "$WAIT_TIME" ]; then
        wait $WAIT_TIME || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -d "op=$FORM_OP" \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d "referer=$FORM_REFERER" \
        -d "method_free=$FORM_METHOD_F" \
        -d 'down_direct=1' \
        -d "password=$LINK_PASSWORD" \
        "$URL") || return

    ERROR=$(echo "$PAGE" | parse_tag_quiet 'class="err"' 'p')
    if [ "$ERROR" = 'Wrong password' ]; then
        return $ERR_LINK_PASSWORD_REQUIRED
    elif [ "$ERROR" = 'Skipped countdown' ]; then
        # Can do a retry
        log_debug "Remote error: $ERROR"
        return $ERR_NETWORK
    elif [ -n "$ERROR" ]; then
        log_error "Remote error: $ERROR"
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr '/d/' 'href')
    if match_remote_url "$FILE_URL"; then
        echo "$FILE_URL"
        return 0
    fi

    log_error 'Unexpected content, site updated?'
    return $ERR_FATAL
}

# Upload a file to hipfile.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
hipfile_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://hipfile.com'
    local PAGE FILE_SIZE MAX_SIZE DEL_CODE FILE_ID UPLOAD_ID USER_TYPE
    local PUBLIC_FLAG=0

    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif [ -n "$PREMIUM" ]; then
            log_error 'You must be registered to create premium-only downloads.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    # 2000 MiB limit for account users
    if [ -n "$AUTH" ]; then
        MAX_SIZE=2097152000 # 2000 MiB
    else
        MAX_SIZE=1048576000 # 1000 MiB
    fi

    FILE_SIZE=$(get_filesize "$FILE")
    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$AUTH" ]; then
        hipfile_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

        hipfile_check_freespace "$FILE_SIZE" "$COOKIE_FILE" "$BASE_URL" || return

        if [ -n "$FOLDER" ]; then
            FOLDER_ID=$(hipfile_check_folder "$FOLDER" "$COOKIE_FILE" "$BASE_URL") || return
            log_debug "Folder ID: '$FOLDER_ID'"
        fi

        USER_TYPE='reg'
    else
        USER_TYPE='anon'
    fi

    [ -z "$PRIVATE_FILE" ] && PUBLIC_FLAG=1

    PAGE=$(curl -c "$COOKIE_FILE" -b 'lang=english' -b "$COOKIE_FILE" "$BASE_URL") || return

    local FORM_HTML FORM_ACTION FORM_TMP_SRV FORM_UTYPE FORM_SESS
    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_TMP_SRV=$(echo "$FORM_HTML" | parse_form_input_by_name 'srv_tmp_url') || return
    FORM_UTYPE=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_type')
    # Will be empty on anon upload
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id')

    # Initial js code:
    # for (var i = 0; i < 12; i++) UID += '' + Math.floor(Math.random() * 10);
    # form_action = form_action.split('?')[0] + '?upload_id=' + UID + '&js_on=1' + '&utype=' + utype + '&upload_type=' + upload_type;
    # upload_type: file, url
    # utype: anon, reg
    UPLOAD_ID=$(random d 12)

    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -F 'upload_type=file' \
        -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        -F "file_1=@/dev/null;filename=" \
        --form-string "file_0_descr=$DESCRIPTION" \
        -F "file_0_public=$PUBLIC_FLAG" \
        --form-string "link_rcpt=$TOEMAIL" \
        --form-string "link_pass=$LINK_PASSWORD" \
        -F 'tos=1' \
        -F 'submit_btn=' \
        "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=$FORM_UTYPE" | \
        break_html_lines) || return

    local OP FILE_CODE STATE
    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return

    OP=$(echo "$FORM_HTML" | parse_tag 'op' 'textarea')
    FILE_CODE=$(echo "$FORM_HTML" | parse_tag 'fn' 'textarea')
    STATE=$(echo "$FORM_HTML" | parse_tag 'st' 'textarea')

    log_debug "File Code: '$FILE_CODE'"
    log_debug "State: '$STATE'"

    if [ "$STATE" = 'OK' ]; then
        log_debug 'Upload successfull.'
    elif [ "$STATE" = 'unallowed extension' ]; then
        log_error 'File extension is forbidden.'
        return $ERR_FATAL
    elif [ "$STATE" = 'file is too big' ]; then
        log_error 'Uploaded file is too big.'
        return $ERR_SIZE_LIMIT_EXCEEDED
    elif [ "$STATE" = 'not enough disk space on your account' ]; then
        log_error 'Account space exceeded.'
        return $ERR_SIZE_LIMIT_EXCEEDED
    else
        log_error "Unknown upload state: $STATE"
        return $ERR_FATAL
    fi

    # Get killcode, file_id and generate links
    # Note: At this point we know the upload state is "OK" due to "if" above
    PAGE=$(curl -b "$COOKIE_FILE" \
        -F "fn=$FILE_CODE" \
        -F "st=$STATE" \
        -F "op=$OP" \
        --form-string "link_rcpt=$TOEMAIL" \
        "$BASE_URL") || return

    DEL_CODE=$(echo "$PAGE" | parse 'killcode=' 'killcode=\([[:alnum:]]\+\)') || return
    FILE_ID=$(echo "$PAGE" | parse 'id="ic0-' 'id="ic0-\([0-9]\+\)') || return

    log_debug "File ID: '$FILE_ID'"

    LINK="$BASE_URL/$FILE_CODE"
    DEL_LINK="$BASE_URL/$FILE_CODE?killcode=$DEL_CODE"

    # Move file to a folder?
    if [ -n "$FOLDER" ]; then
        log_debug 'Moving file...'

        # Source folder ("fld_id") is always root ("0") for newly uploaded files
        PAGE=$(curl -b "$COOKIE_FILE" -i \
            -F 'op=my_files' \
            -F 'fld_id=0' \
            -F "file_id=$FILE_ID" \
            -F "to_folder=$FOLDER_ID" \
            -F 'to_folder_move=Move files' \
            "$BASE_URL") || return

        PAGE=$(echo "$PAGE" | grep_http_header_location_quiet)
        match '?op=my_files' "$PAGE" || log_error 'Could not move file. Site update?'
    fi

    # Set premium only flag
    if [ -n "$PREMIUM" ]; then
        log_debug 'Setting premium flag...'

        PAGE=$(curl -b "$COOKIE_FILE" -G \
            -d 'op=my_files' \
            -d "file_id=$FILE_ID" \
            -d 'set_premium_only=true' \
            -d 'rnd='$(random js) \
            "$BASE_URL") || return

        [ "$PAGE" != "\$\$('tpo$FILE_ID').className='pub';" ] && \
            log_error 'Could not set premium only flag. Site update?'
    fi

    echo "$LINK"
    echo "$DEL_LINK"
}

# Delete a file uploaded to hipfile.com
# $1: cookie file (unused here)
# $2: delete url
hipfile_delete() {
    local -r URL=$2
    local -r BASE_URL='http://hipfile.com'
    local PAGE FILE_ID FILE_DEL_ID

    if ! match 'killcode=[[:alnum:]]\+' "$URL"; then
        log_error 'Invalid URL format'
        return $ERR_BAD_COMMAND_LINE
    fi

    FILE_ID=$(parse . "^$BASE_URL/\([[:alnum:]]\+\)" <<< "$URL")
    FILE_DEL_ID=$(parse . 'killcode=\([[:alnum:]]\+\)$' <<< "$URL")

    PAGE=$(curl -b 'lang=english' -e "$URL" \
        -d 'op=del_file' \
        -d "id=$FILE_ID" \
        -d "del_id=$FILE_DEL_ID" \
        -d 'confirm=yes' \
        "$BASE_URL/") || return

    if match 'File deleted successfully' "$PAGE"; then
        return 0
    elif match 'No such file exist' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match 'Wrong Delete ID' "$PAGE"; then
        log_error 'Wrong delete ID'
    fi

    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: hipfile.com url
# $3: requested capability list
# stdout: 1 capability per line
hipfile_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -b 'lang=english' "$URL") || return

    if match 'File Not Found\|file was removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_REFERER FORM_RAND FORM_METHOD_F
    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname') || return
    FORM_REFERER=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'referer')
    FORM_METHOD_F=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -d "op=$FORM_OP" \
        -d "usr_login=$FORM_USR" \
        -d "id=$FORM_ID" \
        --data-urlencode "fname=$FORM_FNAME" \
        -d "referer=$FORM_REFERER" \
        -d "method_free=$FORM_METHOD_F" \
        "$URL") || return

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$FORM_FNAME" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    # Different layout for premium-only links
    if [[ $REQ_IN = *s* ]]; then
        if match 'This file is available for Premium Users only' "$PAGE"; then
            FILE_SIZE=$(parse 'File:' \
                '\[.*>\(.*\)<.*\]' <<< "$PAGE") && \
                translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
        else
            FILE_SIZE=$(parse 'Size:' \
                '<td>\(.*\)$' <<< "$PAGE") && \
                translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
        fi
    fi

    echo $REQ_OUT
}

# List a hipfile.com web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
hipfile_list() {
    local -r URL=$1
    local -r REC=$2
    local RET=$ERR_LINK_DEAD
    local PAGE LINKS NAMES ERROR PAGE_NUMBER LAST_PAGE

    PAGE=$(curl -b 'lang=english' "$URL") || return

    ERROR=$(echo "$PAGE" | parse_tag_quiet 'class="err"' 'font')
    if [ "$ERROR" = 'No such user exist' ]; then
        return $ERR_LINK_DEAD
    elif [ -n "$ERROR" ]; then
        log_error "Remote error: $ERROR"
        return $ERR_FATAL
    fi

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'class="link"' 'href')
    NAMES=$(echo "$PAGE" | parse_all_tag_quiet 'class="link"' 'a')

    # Parse page buttons panel if exist
    LAST_PAGE=$(echo "$PAGE" | parse_tag_quiet 'class="paging"' 'div' | break_html_lines | \
        parse_all_quiet . 'page=\([0-9]\+\)')

    if [ -n "$LAST_PAGE" ];then
        # The last button is 'Next', last page button right before
        LAST_PAGE=$(echo "$LAST_PAGE" | delete_last_line | last_line)

        for (( PAGE_NUMBER=2; PAGE_NUMBER<=LAST_PAGE; PAGE_NUMBER++ )); do
            log_debug "Listing page #$PAGE_NUMBER"

            PAGE=$(curl -G \
                -d "page=$PAGE_NUMBER" \
                "$URL") || return

            LINKS=$LINKS$'\n'$(echo "$PAGE" | parse_all_attr_quiet 'class="link"' 'href')
            NAMES=$NAMES$'\n'$(echo "$PAGE" | parse_all_tag_quiet 'class="link"' 'a')
        done
    fi

    list_submit "$LINKS" "$NAMES" && RET=0

    # Are there any subfolders?
    if [ -n "$REC" ]; then
        local FOLDERS FOLDER

        FOLDERS=$(echo "$PAGE" | parse_all_attr_quiet 'folder2.gif' 'href') || return

        # First folder can be parent folder (". .") - drop it to avoid infinite loops
        FOLDER=$(echo "$PAGE" | parse_tag_quiet 'folder2.gif' 'b') || return
        [ "$FOLDER" = '. .' ] && FOLDERS=$(echo "$FOLDERS" | delete_first_line)

        while read FOLDER; do
            [ -z "$FOLDER" ] && continue
            log_debug "Entering sub folder: $FOLDER"
            hipfile_list "$FOLDER" "$REC" && RET=0
        done <<< "$FOLDERS"
    fi

    return $RET
}
