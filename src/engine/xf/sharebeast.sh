#!/bin/bash
#
# sharebeast callbacks
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

declare -gA SHAREBEAST_FUNCS
SHAREBEAST_FUNCS['pr_parse_file_name']='sharebeast_pr_parse_file_name'
SHAREBEAST_FUNCS['pr_parse_file_size']='sharebeast_pr_parse_file_size'
SHAREBEAST_FUNCS['ul_get_space_data']='sharebeast_ul_get_space_data'

sharebeast_pr_parse_file_name() {
    local -r PAGE=$1
    local FILE_NAME

    FILE_NAME=$(parse_tag_quiet 'title' <<< "$PAGE")

    echo "$FILE_NAME"
}

sharebeast_pr_parse_file_size() {
    local -r PAGE=$1
    local FILE_SIZE

    FILE_SIZE=$(parse_quiet 'Size' 'class="inlinfo1">\([^<]\+\)' <<< "$PAGE")

    echo "$FILE_SIZE"
}

sharebeast_ul_get_space_data() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE SPACE_USED SPACE_LIMIT

    PAGE=$(curl -b 'lang=english' -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    # XXX Kb of XXX GB
    SPACE_USED=$(parse_quiet 'Used space' '^[[:space:]]*\([0-9.]\+[[:space:]]*[KMGBb]\+\?\) of ' 1 \
        <<< "$PAGE")

    SPACE_LIMIT=$(parse_quiet 'Used space' 'of \([0-9.]\+[[:space:]]*[KMGBb]\+\)' 1 \
        <<< "$PAGE")

    echo "$SPACE_USED"
    echo "$SPACE_LIMIT"
}
