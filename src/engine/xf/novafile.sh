#!/bin/bash
#
# novafile callbacks
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

declare -gA NOVAFILE_FUNCS
NOVAFILE_FUNCS['ul_parse_file_id']='novafile_ul_parse_file_id'
NOVAFILE_FUNCS['login']='novafile_login'
NOVAFILE_FUNCS['ul_get_folder_id']='novafile_ul_get_folder_id'
NOVAFILE_FUNCS['ul_move_file']='novafile_ul_move_file'
NOVAFILE_FUNCS['ul_parse_result']='novafile_ul_parse_result'
NOVAFILE_FUNCS['pr_parse_file_size']='novafile_pr_parse_file_size'
NOVAFILE_FUNCS['ul_get_space_data']='novafile_ul_get_space_data'

novafile_ul_parse_result() {
    local PAGE=$1

    local STATE OP FORM_LINK_RCPT FILE_CODE DEL_CODE
    local FORM_HTML ERROR FORM_ACTION

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1' 2>/dev/null | break_html_lines_alt)

    if [ -z "$FORM_HTML" ]; then
        ERROR=$(echo "$PAGE" | parse_quiet '[Ee][Rr][Rr][Oo][Rr]:' "[Ee][Rr][Rr][Oo][Rr]:[[:space:]]*\(.*\)')")
        if [ -n "$ERROR" ]; then
            log_error "Remote error: '$ERROR'"
        else
            log_error 'Unexpected content.'
        fi

        return $ERR_FATAL
    fi

    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return

    OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FILE_CODE=$(echo "$FORM_HTML" | parse_form_input_by_name 'fn') || return
    STATE=$(echo "$FORM_HTML" | parse_form_input_by_name 'st') || return
    FORM_LINK_RCPT=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'link_rcpt')
    [ -n "$FORM_LINK_RCPT" ] && FORM_LINK_RCPT="--form-string link_rcpt=$FORM_LINK_RCPT"

    echo "$STATE"
    echo "$FILE_CODE"
    echo "$DEL_CODE"
    echo "$FILE_NAME"
    echo "$FORM_ACTION"
    echo "$OP"
    echo "$FORM_LINK_RCPT"
}

novafile_ul_parse_file_id() {
    local PAGE=$1

    FILE_ID=$(echo "$PAGE" | parse_quiet 'id="l[0-9]-' 'id="l[0-9]-\([0-9]\+\)')

    if [ -z "$FILE_ID" ]; then
        if match 'id="l[0-9]-"' "$PAGE"; then
            log_debug 'File ID display most probably disabled.'
        else
            log_debug 'File ID is missing on upload result page.'
        fi
    fi

    echo "$FILE_ID"
}

novafile_login() {
    #local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    #local -r AUTH=$3
    #local LOGIN_URL=$4

    local LOGIN_URL="$BASE_URL/login"

    xfilesharing_login_generic "$@" "$LOGIN_URL"
}

novafile_ul_get_folder_id() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r NAME=$3

    local PAGE FOLDERS FOLDER_ID

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    # <li id="12345"><a href="#">Folder Name</a>
    # first will be root id=0
    FOLDERS=$(echo "$PAGE" | parse_all_tag_quiet '<li id="[0-9]\+"><a href="#">.*</a>' 'a' | delete_first_line) || return

    if match "^$NAME$" "$FOLDERS"; then
        FOLDER_ID=$(echo "$PAGE" | parse_attr "<li id=\"[0-9]\+\"><a href=\"#\">$NAME</a>" 'id')
    fi

    if [ -n "$FOLDER_ID" ]; then
        log_debug "Folder ID: '$FOLDER_ID'"

        echo "$FOLDER_ID"
    fi

    return 0
}

novafile_ul_move_file() {
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

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)

    if match '?op=my_files' "$LOCATION"; then
        log_debug 'File moved.'
    else
        log_error 'Could not move file.'
    fi

    return 0
}

novafile_pr_parse_file_size() {
    local -r PAGE=$1
    local FILE_SIZE

    FILE_SIZE=$(parse_tag_quiet '<div class="size">' 'div' <<< "$PAGE")

    echo "$FILE_SIZE"
}

novafile_ul_get_space_data() {
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
