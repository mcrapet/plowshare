#!/bin/bash
#
# novafile callbacks
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

xfcb_novafile_ul_parse_data() {
    local -r PAGE=$1

    local FORM_UTYPE FORM_SESS
    local FORM_HTML FORM_ACTION FORM_TMP_SRV FORM_SRV_ID
    local FORM_HTML_REMOTE FORM_ACTION_REMOTE FORM_TMP_SRV_REMOTE FORM_SRV_ID_REMOTE

    FORM_HTML=$(grep_form_by_name "$PAGE" 'file' 2>/dev/null)
    FORM_HTML_REMOTE=$(grep_form_by_name "$PAGE" 'url' 2>/dev/null)

    if [ -z "$FORM_HTML" ]; then
        log_error 'Wrong upload page or anonymous uploads not allowed.'
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_ACTION_REMOTE=$(parse_form_action <<< "$FORM_HTML_REMOTE") || return

    FORM_USER_TYPE=$(parse_form_input_by_name 'utype' <<< "$FORM_HTML_REMOTE") || return

    if [ -n "$FORM_USER_TYPE" ]; then
        log_debug "User type: '$FORM_USER_TYPE'"
    fi

    # Will be empty on anon upload
    FORM_SESS=$(parse_form_input_by_name_quiet 'sess_id' <<< "$FORM_HTML")
    [ -n "$FORM_SESS" ] && FORM_SESS="-F sess_id=$FORM_SESS"

    FORM_SRV_TMP=$(parse_form_input_by_name_quiet 'srv_tmp_url' <<< "$FORM_HTML")
    [ -n "$FORM_SRV_TMP" ] && FORM_SRV_TMP="-F srv_tmp_url=$FORM_SRV_TMP"

    FORM_SRV_ID=$(parse_form_input_by_name_quiet 'srv_id' <<< "$FORM_HTML")
    [ -n "$FORM_SRV_ID" ] && FORM_SRV_ID="-F srv_id=$FORM_SRV_ID"

    FORM_SRV_TMP_REMOTE=$(parse_form_input_by_name_quiet 'srv_tmp_url' <<< "$FORM_HTML_REMOTE")
    [ -n "$FORM_SRV_TMP_REMOTE" ] && FORM_SRV_TMP_REMOTE="-F srv_tmp_url=$FORM_SRV_TMP_REMOTE"

    FORM_SRV_ID_REMOTE=$(parse_form_input_by_name_quiet 'srv_id' <<< "$FORM_HTML_REMOTE")
    [ -n "$FORM_SRV_ID_REMOTE" ] && FORM_SRV_ID_REMOTE="-F srv_id=$FORM_SRV_ID_REMOTE"

    FORM_FILE_FIELD='file_0'
    FORM_REMOTE_URL_FIELD="url_mass"

    echo "$FORM_USER_TYPE"
    echo "$FORM_SESS"
    echo "$FORM_ACTION"
    echo "$FORM_SRV_TMP"
    echo "$FORM_SRV_ID"
    echo "$FORM_ACTION_REMOTE"
    echo "$FORM_SRV_TMP_REMOTE"
    echo "$FORM_SRV_ID_REMOTE"
    echo "$FORM_FILE_FIELD"
    echo "$FORM_REMOTE_URL_FIELD"
}

xfcb_novafile_ul_commit() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$(basename_url "$2")
    local -r FILE=$3
    local -r DEST_FILE=$4
    local -r FORM_DATA=$5

    local FORM_HTML FORM_SESS FORM_SRV_TMP FORM_SRV_ID FORM_DISK_ID FORM_DISK_ID_URL FORM_SUBMIT_BTN FILE_FIELD FORM_REMOTE_URL_FIELD FORM_ADD

    IFS=
    {
    read -r FORM_USER_TYPE
    read -r FORM_SESS
    read -r FORM_ACTION
    read -r FORM_SRV_TMP
    read -r FORM_SRV_ID
    read -r FORM_ACTION_REMOTE
    read -r FORM_SRV_TMP_REMOTE
    read -r FORM_SRV_ID_REMOTE
    read -r FORM_FILE_FIELD
    read -r FORM_REMOTE_URL_FIELD
    } <<<"$FORM_DATA"
    unset IFS

    if [ -z "$PRIVATE_FILE" ]; then
        PUBLIC_FLAG=1
    else
        PUBLIC_FLAG=0
    fi

    # Initial js code:
    # for (var i = 0; i < 12; i++) UID += '' + Math.floor(Math.random() * 10);
    # form_action = form_action.split('?')[0] + '?upload_id=' + UID + '&js_on=1' + '&utype=' + utype + '&upload_type=' + upload_type;
    # upload_type: file, url
    # utype: anon, reg
    UPLOAD_ID=$(random d 12)

    # Upload remote file
    if match_remote_url "$FILE"; then
        # url_proxy	- http proxy
        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -i \
            -H 'Expect: ' \
            -F "upload_type=url" \
            $FORM_SESS \
            $FORM_SRV_TMP_REMOTE \
            $FORM_SRV_ID_REMOTE \
            -F "${FORM_REMOTE_URL_FIELD}=$FILE" \
            $FORM_TOEMAIL \
            $FORM_PASSWORD \
            -F "utype=$FORM_USER_TYPE" \
            -F "tos=1" \
            -F "submit_btn=" \
            -F "mass_upload=1" \
            "${FORM_ACTION_REMOTE}/?X-Progress-ID=${UPLOAD_ID}0" | \
            break_html_lines) || return

    # Upload local file
    else
        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -i \
            -H 'Expect: ' \
            -F 'upload_type=file' \
            $FORM_SESS \
            $FORM_SRV_TMP \
            $FORM_SRV_ID \
            $FORM_DISK_ID \
            -F "${FORM_FILE_FIELD}=@$FILE;filename=$DESTFILE" \
            --form-string "${FORM_FILE_FIELD}_descr=$DESCRIPTION" \
            -F "${FORM_FILE_FIELD}_public=$PUBLIC_FLAG" \
            --form-string "link_rcpt=$TOEMAIL" \
            --form-string "link_pass=$LINK_PASSWORD" \
            -F 'tos=1' \
            -F "submit_btn=" \
            $FORM_ADD \
            "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${FORM_USER_TYPE}&upload_type=file$FORM_DISK_ID_URL" | \
            break_html_lines) || return
    fi

    echo "$PAGE"
}

xfcb_novafile_ul_parse_result() {
    local PAGE=$1

    local STATE OP FORM_LINK_RCPT FILE_CODE DEL_CODE
    local FORM_HTML ERROR FORM_ACTION

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1' 2>/dev/null | \
        replace '<input' $'\n<input' | replace '<textarea' $'\n<textarea')

    if [ -z "$FORM_HTML" ]; then
        ERROR=$(parse_quiet '[Ee][Rr][Rr][Oo][Rr]:' "[Ee][Rr][Rr][Oo][Rr]:[[:space:]]*\(.*\)')" <<< "$PAGE")
        if [ -n "$ERROR" ]; then
            log_error "Remote error: '$ERROR'"
        else
            log_error 'Upload failed. Unexpected content.'
        fi

        return $ERR_FATAL
    fi

    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return

    if match "<input[^>]*name='op'" "$FORM_HTML"; then
        OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
        FILE_CODE=$(parse_form_input_by_name 'fn' <<< "$FORM_HTML") || return
        STATE=$(parse_form_input_by_name 'st' <<< "$FORM_HTML") || return

        FORM_LINK_RCPT=$(parse_form_input_by_name_quiet 'link_rcpt' <<< "$FORM_HTML")
        [ -n "$FORM_LINK_RCPT" ] && FORM_LINK_RCPT="--form-string link_rcpt=$FORM_LINK_RCPT"

    elif match "<textarea name='op'>" "$FORM_HTML"; then
        OP=$(parse_tag "name=[\"']\?op[\"']\?" 'textarea' <<< "$FORM_HTML") || return
        FILE_CODE=$(parse_tag "name=[\"']\?fn[\"']\?" 'textarea' <<< "$FORM_HTML") || return
        STATE=$(parse_tag "name=[\"']\?st[\"']\?" 'textarea' <<< "$FORM_HTML") || return

        FORM_LINK_RCPT=$(parse_tag_quiet "name=[\"']\?link_rcpt[\"']\?" 'textarea' <<< "$FORM_HTML")
        [ -n "$FORM_LINK_RCPT" ] && FORM_LINK_RCPT="--form-string link_rcpt=$FORM_LINK_RCPT"

    else
        log_error 'Upload failed. Unexpected content.'
        return $ERR_FATAL
    fi

    echo "$STATE"
    echo "$FILE_CODE"
    echo "$DEL_CODE"
    echo "$FILE_NAME"
    echo "$FORM_ACTION"
    echo "$OP"
    echo "$FORM_LINK_RCPT"
}

xfcb_novafile_ul_parse_file_id() {
    local PAGE=$1

    FILE_ID=$(parse_quiet 'id="l[0-9]-' 'id="l[0-9]-\([0-9]\+\)' <<< "$PAGE")

    if [ -z "$FILE_ID" ]; then
        if match 'id="l[0-9]-"' "$PAGE"; then
            log_debug 'File ID display most probably disabled.'
        else
            log_debug 'File ID is missing on upload result page.'
        fi
    fi

    echo "$FILE_ID"
}

xfcb_novafile_login() {
    #local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    #local -r AUTH=$3
    #local LOGIN_URL=$4

    local LOGIN_URL="$BASE_URL/login"

    xfcb_generic_login "$@" "$LOGIN_URL"
}

xfcb_novafile_ul_get_folder_id() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r NAME=$3

    local PAGE FOLDERS FOLDER_ID

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    # <li id="12345"><a href="#">Folder Name</a>
    # first will be root id=0
    FOLDERS=$(parse_all_tag_quiet '<li id="[0-9]\+"><a href="#">.*</a>' 'a' <<< "$PAGE") || return
    FOLDERS=$(delete_first_line <<< "$FOLDERS") || return

    if match "^$NAME$" "$FOLDERS"; then
        FOLDER_ID=$(parse_attr "<li id=\"[0-9]\+\"><a href=\"#\">$NAME</a>" 'id' <<< "$PAGE") || return
    fi

    if [ -n "$FOLDER_ID" ]; then
        log_debug "Folder ID: '$FOLDER_ID'"

        echo "$FOLDER_ID"
    fi

    return 0
}

xfcb_novafile_ul_move_file() {
    local COOKIE_FILE=$1
    local BASE_URL=$2
    local FILE_ID=$3
    local FOLDER_DATA=$4

    local PAGE LOCATION FOLDER_ID

    { read FOLDER_ID; } <<<"$FOLDER_DATA"

    # Source folder ("fld_id") is always root ("0") for newly uploaded files
    PAGE=$(curl -b "$COOKIE_FILE" -i \
        -H 'Expect: ' \
        -F 'op=my_files' \
        -F 'fld_id=0' \
        -F "file_id=$FILE_ID" \
        -F "to_folder=$FOLDER_ID" \
        -F 'op_spec=move' \
        -F 'move_copy_action=1' \
        "$BASE_URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    if match '?op=my_files' "$LOCATION"; then
        log_debug 'File moved.'
    else
        log_error 'Could not move file.'
    fi

    return 0
}

xfcb_novafile_pr_parse_file_size() {
    local -r PAGE=$1
    local FILE_SIZE

    FILE_SIZE=$(parse_tag_quiet '<div class="size">' 'div' <<< "$PAGE")

    echo "$FILE_SIZE"
}

xfcb_novafile_ul_get_space_data() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE SPACE_USED SPACE_LIMIT

    PAGE=$(curl -b 'lang=english' -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    # XXX Kb of XXX GB
    SPACE_USED=$(parse_quiet 'Account usage:' ' \([0-9.]\+[[:space:]]*[KMGBb]\+\?\) of ' \
        <<< "$PAGE")

    SPACE_LIMIT=$(parse_quiet 'Account usage:' 'of \([0-9.]\+[[:space:]]*[KMGBb]\+\)' \
        <<< "$PAGE")

    echo "$SPACE_USED"
    echo "$SPACE_LIMIT"
}
