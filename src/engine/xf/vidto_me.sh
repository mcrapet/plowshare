#!/bin/bash
#
# vidto_me callbacks
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

declare -gA VIDTO_ME_FUNCS
VIDTO_ME_FUNCS['pr_parse_file_name']='vidto_me_pr_parse_file_name'
VIDTO_ME_FUNCS['pr_parse_file_size']='vidto_me_pr_parse_file_size'
VIDTO_ME_FUNCS['ls_parse_links']='vidto_me_ls_parse_links'
VIDTO_ME_FUNCS['ls_parse_names']='vidto_me_ls_parse_names'
VIDTO_ME_FUNCS['ls_parse_folders']='vidto_me_ls_parse_folders'
VIDTO_ME_FUNCS['ul_remote_queue_test']='vidto_me_ul_remote_queue_test'
VIDTO_ME_FUNCS['ul_get_file_code']='vidto_me_ul_get_file_code'

vidto_me_pr_parse_file_name() {
    local -r PAGE=$1
    local FILE_NAME

    FILE_NAME=$(parse_quiet '<Title>' '^[[:space:]]*\(.*\) - Vidto$' 3 <<< "$PAGE")

    echo "${FILE_NAME// /_}.mp4"
}

vidto_me_pr_parse_file_size() {
    return 0
}

vidto_me_ls_parse_links() {
    local PAGE=$1
    local LINKS

    LINKS=$(parse_all_quiet '| by <a href="' 'href="\([^"]\+\)' -5 <<< "$PAGE")

    echo "$LINKS"
}

vidto_me_ls_parse_names() {
    local PAGE=$1
    local NAMES

    NAMES=$(parse_all_quiet '| by <a href="' '.html">\([^<]\+\)' -5 <<< "$PAGE")

    echo "$NAMES"
}

vidto_me_ls_parse_folders() {
    return 0
}

vidto_me_ul_remote_queue_test() {
    #local -r PAGE=$1

    echo 'upload_url'
}

vidto_me_ul_get_file_code() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE FILE_CODE

    log_debug 'Trying to get file code form user page...'

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    FILE_CODE=$(parse_quiet '<a class="title" href="' 'href="http://.*/\([[:alnum:]]\{12\}\)' <<< "$PAGE")
    if [ -z "$FILE_CODE" ]; then
        log_error 'Cannot get file CODE from user page.'
        return $ERR_FATAL
    else
        echo "$FILE_CODE"
        return 0
    fi
}
