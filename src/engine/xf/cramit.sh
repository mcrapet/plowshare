#!/bin/bash
#
# cramit callbacks
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

declare -gA CRAMIT_FUNCS
CRAMIT_FUNCS['dl_parse_form1']='cramit_dl_parse_form1'
CRAMIT_FUNCS['ls_parse_links']='cramit_ls_parse_links'
CRAMIT_FUNCS['ls_parse_names']='cramit_ls_parse_names'
CRAMIT_FUNCS['ls_parse_folders']='cramit_ls_parse_folders'
CRAMIT_FUNCS['ul_remote_queue_test']='cramit_ul_remote_queue_test'
CRAMIT_FUNCS['ul_remote_queue_add']='cramit_ul_remote_queue_add'
CRAMIT_FUNCS['ul_remote_queue_del']='cramit_ul_remote_queue_del'
CRAMIT_FUNCS['ul_remote_queue_check']='cramit_ul_remote_queue_check'
CRAMIT_FUNCS['ul_get_file_code']='cramit_ul_get_file_code'

cramit_dl_parse_form1() {
    cramit_dl_parse_form1 "$1" '' '' '' '' '' '' 'freemethod'
}

cramit_ls_parse_links() {
    local PAGE=$1
    local LINKS

    PAGE=$(replace '<TR' $'\n<TR' <<< "$PAGE")

    LINKS=$(parse_all_attr_quiet 'TD rowspan=4 class="img" width=15%' 'href' <<< "$PAGE")

    echo "$LINKS"
}

cramit_ls_parse_names() {
    local PAGE=$1
    local NAMES

    PAGE=$(replace '<TR' $'\n<TR' <<< "$PAGE")

    NAMES=$(parse_all_tag_quiet 'TD rowspan=4 class="img" width=15%' 'a' <<< "$PAGE")

    echo "$NAMES"
}

cramit_ls_parse_folders() {
    local PAGE=$1

    PAGE=$(replace '<TR' $'\n<TR' <<< "$PAGE")

    xfilesharing_ls_parse_folders_generic "$PAGE"
}

cramit_ul_remote_queue_test() {
    #local -r PAGE=$1

    echo 'uploader2'
}

cramit_ul_remote_queue_add() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r FILE=$3
    local -r REMOTE_UPLOAD_QUEUE_OP=$4

    local PAGE

    PAGE=$(curl_with_log -b "$COOKIE_FILE" -b 'lang=english' -i \
        -F "op=$REMOTE_UPLOAD_QUEUE_OP" \
        -F 'type=mass_remote_upload' \
        -F "remote_mass_url=$FILE" \
        -F 'tos=1' \
        -F 'download=QUEUE FOR UPLOAD' \
        "$BASE_URL/") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")
    if ! match '?op=uploader2' "$LOCATION"; then
        log_error 'Failed to add new URL into queue.'
        return $ERR_FATAL
    fi

    return 0
}

cramit_ul_remote_queue_del() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r REMOTE_UPLOAD_QUEUE_OP=$3

    local PAGE DEL_ID LOCATION

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' -G \
        -d "op=$REMOTE_UPLOAD_QUEUE_OP" \
        "$BASE_URL/" | replace '<a' $'\n<a') || return

    DEL_ID=$(parse 'del_download=' 'del_download=\([0-9]\+\)' <<< "$PAGE") || return

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' -i -G \
        -d "op=$REMOTE_UPLOAD_QUEUE_OP;del_download=$DEL_ID" \
        "$BASE_URL/") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")
    if match "?op=$REMOTE_UPLOAD_QUEUE_OP" "$LOCATION"; then
        log_debug 'URL removed.'
    else
        log_error 'Cannot remove URL from queue.'
    fi

    return 0
}

cramit_ul_remote_queue_check() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r REMOTE_UPLOAD_QUEUE_OP=$3

    local PAGE

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' -G \
        -d "op=$REMOTE_UPLOAD_QUEUE_OP" \
        "$BASE_URL/") || return

    if match '<TD[^>]*>PENDING</TD>\|<TD[^>]*>WORKING</TD>' "$PAGE"; then
        log_debug "QUEUE: found working"
        return 1
    elif match '?op=$REMOTE_UPLOAD_QUEUE_OP;del_download=' "$PAGE"; then
        log_debug "QUEUE: found error"
        parse_quiet '<TD[^>]*>ERROR:' '<TD[^>]*>ERROR:\([^<]\+\)' <<< "$PAGE"
        return 2
    else
        log_debug "QUEUE: found nothing"
        return 0
    fi
}

cramit_ul_get_file_code() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE FILE_CODE

    log_debug 'Trying to get file code form user page...'

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    FILE_CODE=$(parse_quiet "<input[^>]*name=['\"]\?file_id['\"]\?" 'href="https\?://.*/\([[:alnum:]]\{12\}\)' <<< "$PAGE")
    if [ -z "$FILE_CODE" ]; then
        log_error 'Cannot get file CODE from user page.'
        return $ERR_FATAL
    else
        echo "$FILE_CODE"
        return 0
    fi
}
