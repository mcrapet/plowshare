#!/bin/bash
#
# uptobox callbacks
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

xfilesharing:uptobox_ul_get_space_data() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE SPACE_USED SPACE_LIMIT

    PAGE=$(curl -b 'lang=english' -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    # XXX Kb of XXX GB
    SPACE_USED=$(parse_quiet 'Used space' '^[[:space:]]*\([0-9.]\+[[:space:]]*[KMGBb]\+\?\)$' 5 \
        <<< "$PAGE")

    SPACE_LIMIT=$(parse_quiet 'Used space' 'of \([0-9.]\+[[:space:]]*[KMGBb]\+\)' 8 \
        <<< "$PAGE")

    echo "$SPACE_USED"
    echo "$SPACE_LIMIT"
}

xfilesharing:uptobox_ls_parse_links() {
    local PAGE=$1
    local LINKS

    LINKS=$(parse_all_attr_quiet '<TD align=left><a href="' 'href' <<< "$PAGE")

    echo "$LINKS"
}

xfilesharing:uptobox_ls_parse_names() {
    local PAGE=$1
    local NAMES

    NAMES=$(parse_all_tag_quiet '<TD align=left><a href="' 'a' <<< "$PAGE")

    echo "$NAMES"
}

xfilesharing:uptobox_ls_parse_folders() {
    local PAGE=$1
    local FOLDERS USERNAME

    USERNAME=$(parse_quiet '<title>Files of ' '<title>Files of \([^:]\+\)' <<< "$PAGE")
    FOLDERS=$(parse_all_attr_quiet '<TD colspan=4>' 'href' <<< "$PAGE")

    [ -n "$FOLDERS" ] && \
        FOLDERS=$(replace '?op=my_files&amp;fld_id=' "http://uptobox.com/users/$USERNAME/" <<< "$FOLDERS")

    echo "$FOLDERS"
}
