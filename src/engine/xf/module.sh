#!/bin/bash
#
# xfilesharing base module
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

MODULE_XFILESHARING_GENERIC_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_XFILESHARING_GENERIC_DOWNLOAD_RESUME=yes
MODULE_XFILESHARING_GENERIC_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_XFILESHARING_GENERIC_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=()
MODULE_XFILESHARING_GENERIC_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_XFILESHARING_GENERIC_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
FOLDER,,folder,s=FOLDER,Folder to upload files into
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email
PREMIUM,,premium,,Make file inaccessible to non-premium users
PRIVATE_FILE,,private,,Do not make file visible in folder view
ASYNC,,async,,Asynchronous remote upload"
MODULE_XFILESHARING_GENERIC_UPLOAD_REMOTE_SUPPORT=yes

MODULE_XFILESHARING_GENERIC_DELETE_OPTIONS=

MODULE_XFILESHARING_GENERIC_PROBE_OPTIONS=

MODULE_XFILESHARING_GENERIC_LIST_OPTIONS=
MODULE_XFILESHARING_GENERIC_LIST_HAS_SUBFOLDERS=yes

# Output a file download URL
# $1: cookie file
# $2: file hosting url
# stdout: real file download link
xfcb_download() {
    local -r COOKIE_FILE=$1
    local URL=$2

    local BASE_URL=$(basename_url "$URL")
    local PAGE LOCATION EXTRA FILE_URL WAIT_TIME TIME ERROR
    local FORM_DATA FORM_CAPTCHA FORM_PASSWORD
    local NEW_PAGE=1

    if [ -n "$AUTH" ]; then
        xfcb_login "$COOKIE_FILE" "$BASE_URL" "$AUTH" || return
    fi

    PAGE=$(curl -i -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' "$URL" | \
            strip_html_comments) || return

    PAGE=$(xfcb_check_antiddos "$COOKIE_FILE" "$URL" "$PAGE") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)
    if [ -n "$LOCATION" ] && [ "$LOCATION" != "$URL" ]; then
        if [ $(basename_url "$LOCATION") = "$LOCATION" ]; then
            URL="$BASE_URL/$LOCATION"
        elif match 'op=login' "$LOCATION"; then
            log_error "You must be registered to download."
            return $ERR_LINK_NEED_PERMISSIONS
        else
            URL="$LOCATION"
        fi
        log_debug "New form action: '$URL'"
    fi

    xfcb_dl_parse_error "$PAGE" || return

    xfcb_dl_parse_imagehosting "$PAGE" && return 0

    # Streaming sites like to pack player scripts and place them where they like
    xfcb_dl_parse_streaming "$PAGE" "$URL" && return 0

    # First form sometimes absent
    FORM_DATA=$(xfcb_dl_parse_form1 "$PAGE") || return
    if [ -n "$FORM_DATA" ]; then
        { read -r FILE_NAME_TMP; } <<<"$FORM_DATA"
        [ -n "$FILE_NAME_TMP" ] && FILE_NAME=$(echo "$FILE_NAME_TMP" | parse . '=\(.*\)$')

        WAIT_TIME=$(xfcb_dl_parse_countdown "$PAGE") || return
        if [ -n "$WAIT_TIME" ]; then
            (( WAIT_TIME++ ))
            wait $WAIT_TIME || return
        fi

        PAGE=$(xfcb_dl_commit_step1 "$COOKIE_FILE" "$URL" "$FORM_DATA") || return

        # To avoid double check for errors or streaming if page not updated
        NEW_PAGE=1
    else
        log_debug 'Form 1 omitted.'
    fi

    if [ $NEW_PAGE = 1 ]; then
        xfcb_dl_parse_error "$PAGE" || return
        xfcb_dl_parse_streaming "$PAGE" "$URL" "$FILE_NAME" && return 0
        NEW_PAGE=0
    fi

    FORM_DATA=$(xfcb_dl_parse_form2 "$PAGE") || return
    if [ -n "$FORM_DATA" ]; then
        { read -r FILE_NAME_TMP; } <<<"$FORM_DATA"
        [ -n "$FILE_NAME_TMP" ] && FILE_NAME=$(echo "$FILE_NAME_TMP" | parse . '=\(.*\)$')

        WAIT_TIME=$(xfcb_dl_parse_countdown "$PAGE") || return

        # If password or captcha is too long :)
        [ -n "$WAIT_TIME" ] && TIME=$(date +%s)

        CAPTCHA_DATA=$(xfcb_handle_captcha "$PAGE") || return
        { read FORM_CAPTCHA; read CAPTCHA_ID; } <<<"$CAPTCHA_DATA"

        if [ -n "$WAIT_TIME" ]; then
            TIME=$(($(date +%s) - $TIME))
            if [ $TIME -lt $WAIT_TIME ]; then
                WAIT_TIME=$((WAIT_TIME - $TIME + 1))
                wait $WAIT_TIME || return
            fi
        fi

        PAGE=$(xfcb_dl_commit_step2 "$COOKIE_FILE" "$URL" "$FORM_DATA" \
            "$FORM_CAPTCHA") || return

        # In case of download-after-post system or some complicated link parsing
        #  that requires additional data and page rquests (like uploadc or up.lds.net)
        if match_remote_url $(echo "$PAGE" | first_line); then
            { read FILE_URL; read FILE_NAME_TMP; read EXTRA; } <<<"$PAGE"
            [ -n "$FILE_NAME_TMP" ] && FILE_NAME="$FILE_NAME_TMP"
            [ -n "$EXTRA" ] && eval "$EXTRA"
        else
            NEW_PAGE=1
        fi
    else
        log_debug 'Form 2 omitted.'
    fi

    if [ -z "$FILE_URL" ]; then
        if [ $NEW_PAGE = 1 ]; then
            xfcb_dl_parse_error "$PAGE" || ERROR=$?
            if [ "$ERROR" = "$ERR_CAPTCHA" ]; then
                log_debug 'Wrong captcha'
                [ -n "$CAPTCHA_ID" ] && captcha_nack $CAPTCHA_ID
            fi
            [ -n "$ERROR" ] && return $ERROR
            xfcb_dl_parse_streaming "$PAGE" "$URL" "$FILE_NAME" && return 0
        fi

        # I think it would be correct to use parse fucntion to parse only,
        #  but not make any additional requests
        FILE_DATA=$(xfcb_dl_parse_final_link "$PAGE" "$FILE_NAME") || return
        { read FILE_URL; read FILE_NAME_TMP; read EXTRA; } <<<"$FILE_DATA"
        [ -n "$FILE_NAME_TMP" ] && FILE_NAME="$FILE_NAME_TMP"
        [ -n "$EXTRA" ] && eval "$EXTRA"
    fi

    if match_remote_url "$FILE_URL"; then
        if [ -n "$FORM_CAPTCHA" -a -n "$CAPTCHA_ID" ]; then
            log_debug 'Correct captcha'
            captcha_ack $CAPTCHA_ID
        fi

        echo "$FILE_URL"
        [ -n "$FILE_NAME" ] && echo "$FILE_NAME"
        return 0
    fi

    log_debug 'Link not found'

    # Can be wrong captcha, some sites (cramit.in) do not return any error message
    if [ -n "$FORM_CAPTCHA" ]; then
        log_debug 'Wrong captcha'
        [ -n "$CAPTCHA_ID" ] && captcha_nack $CAPTCHA_ID
        return $ERR_CAPTCHA
    else
        log_error 'Unexpected content.'
    fi

    return $ERR_FATAL
}

# Upload a file to file hosing
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
xfcb_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL=$(echo "$URL_UPLOAD" | parse . "^\(.*\)/")
    local PAGE LOCATION STATE FILE_CODE DEL_CODE FILE_ID FORM_DATA RESULT_DATA
    local FILE_NEED_EDIT=0

    log_debug "Current: $URL_UPLOAD"

    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif [ -n "$PREMIUM" ]; then
            log_error 'You must be registered to create premium-only downloads.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    if [ -n "$AUTH" ]; then
        xfcb_login "$COOKIE_FILE" "$BASE_URL" "$AUTH" || return

        if ! match_remote_url "$FILE"; then
            FILE_SIZE=$(get_filesize "$FILE")
            #if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
            #    log_debug "File is bigger than $MAX_SIZE"
            #    return $ERR_SIZE_LIMIT_EXCEEDED
            #fi

            SPACE_INFO=$(xfcb_ul_get_space_data "$COOKIE_FILE" "$BASE_URL") || return
            { read -r SPACE_USED; read -r SPACE_LIMIT; } <<<"$SPACE_INFO"

            if [ -n "$SPACE_INFO" ]; then
                SPACE_INFO="Space: $SPACE_USED / $SPACE_LIMIT"

                SPACE_USED=$(translate_size "${SPACE_USED/b/B}")
                SPACE_LIMIT=$(translate_size "${SPACE_LIMIT/b/B}")
            fi

            if [ -z "$SPACE_LIMIT" ] || [ "$SPACE_LIMIT" = "0" ]; then
                log_debug 'Space limit not set.'
            else
                log_debug "$SPACE_INFO"

                if (( ( "$SPACE_LIMIT" - "$SPACE_USED" ) < "$FILE_SIZE" )); then
                    log_error 'Not enough space in account folder.'
                    return $ERR_SIZE_LIMIT_EXCEEDED
                fi
            fi
        else
            FILE_NEED_EDIT=1
        fi

        if [ -n "$FOLDER" ]; then
            FOLDER_DATA=$(xfcb_ul_get_folder_data "$COOKIE_FILE" "$BASE_URL" "$FOLDER") || return

            if [ -z "$FOLDER_DATA" ]; then
                xfcb_ul_create_folder "$COOKIE_FILE" "$BASE_URL" "$FOLDER" || return
                FOLDER_DATA=$(xfcb_ul_get_folder_data "$COOKIE_FILE" "$BASE_URL" "$FOLDER") || return
            elif [ "$FOLDER_DATA" = "0" ]; then
                log_debug 'Folders not supported or broken for current submodule.'
            fi
        fi
    fi

    PAGE=$(curl -i -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' \
        "$URL_UPLOAD" | \
        strip_html_comments) || return

    PAGE=$(xfcb_check_antiddos "$COOKIE_FILE" "$URL_UPLOAD" "$PAGE") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)
    if match 'op=login' "$LOCATION"; then
        log_error 'Anonymous upload not allowed.'
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    REMOTE_UPLOAD_QUEUE_OP=$(xfcb_ul_remote_queue_test "$PAGE") || return

    if match_remote_url "$FILE" && [ -n "$REMOTE_UPLOAD_QUEUE_OP" ]; then
        log_debug "Remote upload queue support detected. $REMOTE_UPLOAD_QUEUE_OP."

        xfcb_ul_remote_queue_check "$COOKIE_FILE" "$BASE_URL" "$REMOTE_UPLOAD_QUEUE_OP"
        if [ "$?" != "0" ] && [ -z "$ASYNC" ]; then
            log_error 'Upload queue is not empty. Use asynchronous mode to upload multiple files simultaneously.'
            return $ERR_FATAL
        fi

        xfcb_ul_remote_queue_add "$COOKIE_FILE" "$BASE_URL" "$FILE" "$REMOTE_UPLOAD_QUEUE_OP" || return

        # If this is an async upload, we are done
        # FIXME: fake output, maybe introduce a new exit code?
        if [ -n "$ASYNC" ]; then
            log_error 'Async remote upload, check your account for link.'
            echo '#'
            return 0
        fi

        # Keep checking progress
        TRY=1
        ERROR=$(xfcb_ul_remote_queue_check "$COOKIE_FILE" "$BASE_URL" "$REMOTE_UPLOAD_QUEUE_OP")
        while [ "$?" = "1" ]; do
            log_debug "Wait for server to download the file... [$((TRY++))]"
            wait 15 || return # arbitrary, short wait time
            ERROR=$(xfcb_ul_remote_queue_check "$COOKIE_FILE" "$BASE_URL" "$REMOTE_UPLOAD_QUEUE_OP")
        done

        if [ -n "$ERROR" ]; then
            log_error "Remote upload error: '$ERROR'"
            xfcb_ul_remote_queue_del "$COOKIE_FILE" "$BASE_URL" "$REMOTE_UPLOAD_QUEUE_OP" || return
            return $ERR_FATAL
        fi

        FILE_CODE=$(xfcb_ul_get_file_code "$COOKIE_FILE" "$BASE_URL") || return

    else
        FORM_DATA=$(xfcb_ul_parse_data "$PAGE") || return

        PAGE=$(xfcb_ul_commit "$COOKIE_FILE" "$BASE_URL" "$FILE" "$DEST_FILE" "$FORM_DATA") || return

        RESULT_DATA=$(xfcb_ul_parse_result "$PAGE") || return
        { read STATE; read FILE_CODE; read DEL_CODE; read FILE_NAME; } <<<"$RESULT_DATA"

        if [ -z "$FILE_NAME" ] && [ "$DEST_FILE" != 'dummy' ]; then
            FILE_NAME="$DEST_FILE"
        fi

        if [ "$STATE" = 'EDIT' ]; then
            STATE='OK'
            FILE_NEED_EDIT=1
        fi

        xfcb_ul_handle_state "$STATE" || return

        PAGE=$(xfcb_ul_commit_result "$COOKIE_FILE" "$BASE_URL" "$RESULT_DATA") || return

        if [ -z "$DEL_CODE" -a -n "$PAGE" ]; then
            DEL_CODE=$(xfcb_ul_parse_del_code "$PAGE")
        fi
    fi

    if [ -n "$AUTH" ]; then
        FILE_ID=$(xfcb_ul_parse_file_id "$PAGE")

        [ -z "$FILE_ID" ] && FILE_ID=$(xfcb_ul_get_file_id "$COOKIE_FILE" "$BASE_URL")

        [ -n "$FILE_ID" ] && log_debug "File ID: '$FILE_ID'"
    fi

    # Move file to a folder?
    if [ -n "$FOLDER" -a -z "$FILE_ID" ]; then
        log_error 'Cannot move file without file ID.'
    elif [ -n "$FOLDER" ] && [ "$FOLDER_DATA" = "0" ]; then
        log_error 'Skipping move file.'
    elif [ -n "$FOLDER" ]; then
        xfcb_ul_move_file "$COOKIE_FILE" "$BASE_URL" "$FILE_ID" "$FOLDER_DATA" || return
    fi

    # Edit file if could not set some options during upload
    if [ "$FILE_NEED_EDIT" = 1 ] && \
        [ "$DEST_FILE" != 'dummy' \
        -o -n "$DESCRIPTION" \
        -o -n "$LINK_PASSWORD" ] ; then
        log_debug 'Editing file parameters for remote upload...'

        xfcb_ul_edit_file "$COOKIE_FILE" "$BASE_URL" "$FILE_CODE" "$DEST_FILE" || return

    else
        # Set premium only flag
        if [ -n "$PREMIUM" -a -z "$FILE_ID" ]; then
            log_error 'Cannot set premium flag without file ID.'
        elif [ -n "$PREMIUM" ]; then
            xfcb_ul_set_flag_premium "$COOKIE_FILE" "$BASE_URL" "$FILE_ID" || return
        fi

        # Ensure that correct public flag set on remote upload
        if [ "$FILE_NEED_EDIT" = 1 ] && [ -z "$FILE_ID" ]; then
            log_error 'Cannot set public flag without file ID.'
        elif [ "$FILE_NEED_EDIT" = 1 ]; then
            xfcb_ul_set_flag_public "$COOKIE_FILE" "$BASE_URL" "$FILE_ID" || return
        fi
    fi

    xfcb_ul_generate_links "$BASE_URL" "$FILE_CODE" "$DEL_CODE" "$FILE_NAME"
}

# Delete a file uploaded to file hosting
# $1: cookie file (unused here)
# $2: delete url
xfcb_delete() {
    local -r URL=$2
    local BASE_URL
    local PAGE FILE_ID FILE_DEL_ID

    if match 'killcode=[[:alnum:]]\+' "$URL"; then
        BASE_URL=$(parse . "^\(https\?://.*\)/[[:alnum:]]\{12\}" <<< "$URL") || return

        FILE_ID=$(parse . "^$BASE_URL/\([[:alnum:]]\{12\}\)" <<< "$URL") || return
        FILE_DEL_ID=$(parse . 'killcode=\([[:alnum:]]\+\)' <<< "$URL") || return

        PAGE=$(curl -b 'lang=english' -e "$URL" \
            -d 'op=del_file' \
            -d "id=$FILE_ID" \
            -d "del_id=$FILE_DEL_ID" \
            -d 'confirm=yes' \
            "$BASE_URL/") || return
    elif match '/del-[A-Z0-9]\+-[A-Z0-9]\+' "$URL"; then
        BASE_URL=$(parse . "^\(https\?://.*\)/del-" <<< "$URL") || return

        FILE_ID=$(parse . '/del-\([A-Z0-9]\+\)-[A-Z0-9]\+' <<< "$URL") || return
        FILE_DEL_ID=$(parse . '/del-[A-Z0-9]\+-\([A-Z0-9]\+\)' <<< "$URL") || return

        PAGE=$(curl -b 'lang=english' -e "$URL" -G \
            -d "del=$FILE_ID-$FILE_DEL_ID" \
            -d 'confirm=yes' \
            "$BASE_URL/") || return
    elif match '/[[:alnum:]]\+-del-[[:alnum:]]\+' "$URL"; then
        BASE_URL=$(parse . "^\(https\?://.*\)/[[:alnum:]]\{12\}" <<< "$URL") || return

        FILE_ID=$(parse . '/\([[:alnum:]]\+\)-del-[[:alnum:]]\+' <<< "$URL") || return
        FILE_DEL_ID=$(parse . '/[[:alnum:]]\+-del-\([[:alnum:]]\+\)' <<< "$URL") || return

        PAGE=$(curl -b 'lang=english' -e "$URL" -G \
            -d "del=$FILE_ID-$FILE_DEL_ID" \
            -d 'confirm=yes' \
            "$BASE_URL/") || return
    else
        log_error 'Unknown URL format.'
        return $ERR_BAD_COMMAND_LINE
    fi

    if match 'File deleted successfully' "$PAGE"; then
        return 0
    elif match 'No such file' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match 'Wrong Delete ID' "$PAGE"; then
        log_error 'Wrong delete ID'
    fi

    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file
# $2: file hosting url
# $3: requested capability list
# stdout: 1 capability per line
xfcb_probe() {
    local -r COOKIE_FILE=$1
    local URL=$2
    local -r REQ_IN=$3
    local BASE_URL=$(basename_url "$URL")
    local PAGE FORM_DATA FILE_NAME FILE_NAME_TMP FILE_SIZE REQ_OUT

    PAGE=$(curl -i -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' "$URL" | \
        strip_html_comments) || return

    PAGE=$(xfcb_check_antiddos "$COOKIE_FILE" "$URL" "$PAGE") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")
    if [ -n "$LOCATION" ] && [ "$LOCATION" != "$URL" ]; then
        if [ $(basename_url "$LOCATION") = "$LOCATION" ]; then
            URL="$BASE_URL/$LOCATION"
        elif match 'op=login' "$LOCATION"; then
            log_error "You must be registered to download."
            return $ERR_LINK_NEED_PERMISSIONS
        else
            URL="$LOCATION"
        fi
        log_debug "New form action: '$URL'"
    fi

    # see xfcb_dl_parse_error_generic
    if ! matchi 'No such file.*No such user exist.*File not found' "$PAGE" && \
        matchi 'File Not Found\|file was removed\|No such file' "$PAGE"; then
            return $ERR_LINK_DEAD
    fi

    FORM_DATA=$(xfcb_dl_parse_form1 "$PAGE" 2>/dev/null)
    if [ -n "$FORM_DATA" ]; then
        { read -r FILE_NAME_TMP; } <<<"$FORM_DATA"
        [ -n "$FILE_NAME_TMP" ] && FILE_NAME=$(parse . '=\(.*\)$' <<<"$FILE_NAME_TMP")
    else
        log_debug 'Form 1 omitted.'
    fi

    if [ -z "$FORM_DATA" ] && [ -z "$FILE_NAME" ]; then
        LINK_PASSWORD='dummy'
        FORM_DATA_2=$(xfcb_dl_parse_form2 "$PAGE" 2>/dev/null)
        if [ -n "$FORM_DATA_2" ]; then
            { read -r FILE_NAME_TMP; } <<<"$FORM_DATA_2"
            [ -n "$FILE_NAME_TMP" ] && FILE_NAME=$(echo "$FILE_NAME_TMP" | parse . '=\(.*\)$')
        fi
    fi

    REQ_OUT=c

    for TRY in 1 2; do
        if [ "$TRY" = "2" ]; then
            if [ -n "$FORM_DATA" ] && [ -z "$FILE_NAME" -o -z "$FILE_SIZE" ]; then
                PAGE=$(xfcb_dl_commit_step1 "$COOKIE_FILE" "$URL" "$FORM_DATA") || return
            else
                break
            fi
        fi

        if [[ $REQ_IN = *f* ]] && [[ $REQ_OUT != *f* ]]; then
            [ -z "$FILE_NAME" ] && FILE_NAME=$(xfcb_pr_parse_file_name "$PAGE")
            [ -n "$FILE_NAME" ] && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
        fi

        if [[ $REQ_IN = *s* ]] && [[ $REQ_OUT != *s* ]]; then
            FILE_SIZE=$(xfcb_pr_parse_file_size "$PAGE" "$FILE_NAME")
            [ -n "$FILE_SIZE" ] && translate_size "${FILE_SIZE/b/B}" && REQ_OUT="${REQ_OUT}s"
        fi
    done

    if [[ $REQ_IN = *f* ]] && [ -z "$FILE_NAME" ]; then
        log_error 'Failed to parse file name.'
    fi

    if [[ $REQ_IN = *s* ]] && [ -z "$FILE_SIZE" ]; then
        log_error 'Failed to parse size.'
    fi

    echo $REQ_OUT
}

# List a file hositng web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
xfcb_list() {
    local -r URL=$1
    local -r REC=$2
    local RET=$ERR_LINK_DEAD
    local PAGE LINKS NAMES PAGE_NUMBER LAST_PAGE

    PAGE=$(curl -b 'lang=english' "$URL" | strip_html_comments) || return

    # see xfcb_dl_parse_error_generic
    if ! matchi 'No such file.*No such user exist.*File not found' "$PAGE"; then
        if match 'File Not Found' "$PAGE"; then
            log_error 'Folders are disabled for this hosting.'
            return $ERR_LINK_DEAD
        elif match 'No such user exist'; then
            return $ERR_LINK_DEAD
        fi
    fi

    LINKS=$(xfcb_ls_parse_links "$PAGE")
    NAMES=$(xfcb_ls_parse_names "$PAGE")

    # Parse page buttons panel if exist
    LAST_PAGE=$(xfcb_ls_parse_last_page "$PAGE")

    if [ -n "$LAST_PAGE" ];then
        for (( PAGE_NUMBER=2; PAGE_NUMBER<=LAST_PAGE; PAGE_NUMBER++ )); do
            log_debug "Listing page #$PAGE_NUMBER"

            PAGE=$(curl -G \
                -d "page=$PAGE_NUMBER" \
                "$URL") || return

            LINKS=$LINKS$'\n'$(xfcb_ls_parse_links "$PAGE")
            NAMES=$NAMES$'\n'$(xfcb_ls_parse_names "$PAGE")
        done
    fi

    list_submit "$LINKS" "$NAMES" && RET=0

    # Are there any subfolders?
    if [ -n "$REC" ]; then
        local FOLDERS FOLDER

        FOLDERS=$(xfcb_ls_parse_folders "$PAGE") || return

        while read FOLDER; do
            [ -z "$FOLDER" ] && continue
            log_debug "Entering sub folder: $FOLDER"
            xfcb_list "$FOLDER" "$REC" && RET=0
        done <<< "$FOLDERS"
    fi

    return $RET
}
