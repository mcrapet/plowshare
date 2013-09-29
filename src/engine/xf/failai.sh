#!/bin/bash
#
# failai callbacks
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

declare -gA FAILAI_FUNCS
FAILAI_FUNCS['dl_parse_form1']='failai_dl_parse_form1'
FAILAI_FUNCS['dl_commit_step1']='failai_dl_commit_step1'
FAILAI_FUNCS['dl_parse_error']='failai_dl_parse_error'
FAILAI_FUNCS['ul_create_folder']='failai_ul_create_folder'
FAILAI_FUNCS['ul_get_space_data']='failai_ul_get_space_data'

failai_ul_create_folder() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r NAME=$3

    local PAGE

    PAGE=$(curl -b "$COOKIE_FILE" -i \
        -H 'Expect: ' \
        -d 'op=my_files' \
        -d "fld_parent_id=0" \
        -d "create_new_folder=$NAME" \
        "$BASE_URL/") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)
    if match '?op=my_files' "$LOCATION"; then
        log_debug 'Folder created.'
    else
        log_error 'Could not create folder.'
    fi

    return 0
}

failai_dl_parse_form1() {
    xfilesharing_dl_parse_form1_generic "$1" '' '' '' '' '' '' '' \
        'file_wait'
}

failai_dl_commit_step1() {
    local -r COOKIE_FILE=$1
    local -r FORM_ACTION=$2
    local -r FORM_DATA=$3

    local FORM_HTML FORM_OP FORM_ID FORM_USR FORM_FNAME FORM_REFERER FORM_HASH FORM_METHOD_F FORM_ADD

    PAGE=$(xfilesharing_dl_commit_step1_generic "$@") || return

    if ! match '"download2"' "$PAGE"; then
        FORM_DATA=$(xfilesharing_dl_parse_form1 "$PAGE") || return

        {
        read -r FORM_FNAME
        read -r FORM_OP
        read -r FORM_ID
        read -r FORM_USR
        read -r FORM_REFERER
        read -r FORM_HASH
        read -r FORM_METHOD_F
        read -r FORM_ADD
        } <<<"$FORM_DATA"

        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -d "$FORM_OP" \
        -d "$FORM_USR" \
        -d "$FORM_ID" \
        --data-urlencode "$FORM_FNAME" \
        -d "$FORM_REFERER" \
        $FORM_HASH \
        $FORM_ADD \
        "$FORM_ACTION" | \
        strip_html_comments) || return
    fi

    echo "$PAGE"
}

failai_dl_parse_error() {
    local PAGE=$1

    if match '<font class="err"></font>' "$PAGE"; then
        return 0
    fi

    xfilesharing_dl_parse_error_generic "$@"
}

failai_ul_get_space_data() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE SPACE_USED SPACE_LIMIT

    PAGE=$(curl -b 'lang=english' -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    # XXX Kb of XXX GB
    SPACE_USED=$(parse_quiet 'Used disk space' \
        ' \([0-9.]\+[[:space:]]*[KMGBb]\+\?\) of ' <<< "$PAGE")

    SPACE_LIMIT=$(parse_quiet 'Used disk space' \
        'of \([0-9.]\+[[:space:]]*[KMGBb]\+\)' <<< "$PAGE")

    echo "$SPACE_USED"
    echo "$SPACE_LIMIT"
}
