#!/bin/bash
#
# taruhsini callbacks
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

xfcb_taruhsini_ls_parse_names() {
    local PAGE=$1
    local NAMES

    NAMES=$(xfcb_generic_ls_parse_names "$PAGE")
    NAMES=$(parse_all_quiet . '^<small>\(.*\)</small>$' <<< "$NAMES")

    echo "$NAMES"
}

xfcb_taruhsini_ls_parse_folders() {
    local PAGE=$1
    local FOLDERS FOLDER

    FOLDERS=$(parse_all_attr_quiet '<td width="1%"><img' 'href' <<< "$PAGE") || return

    if [ -n "$FOLDERS" ]; then
        # First folder can be parent folder (". .") - drop it to avoid infinite loops
        FOLDER=$(parse_tag_quiet '<td width="1%"><img' 'b' <<< "$PAGE") || return
        [ "$FOLDER" = '. .' ] && FOLDERS=$(delete_first_line <<< "$FOLDERS")
    fi

    echo "$FOLDERS"
}
