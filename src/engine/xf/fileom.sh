#!/bin/bash
#
# fileom callbacks
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

declare -gA FILEOM_FUNCS
FILEOM_FUNCS['ls_parse_links']='fileom_ls_parse_links'
FILEOM_FUNCS['ls_parse_names']='fileom_ls_parse_names'
FILEOM_FUNCS['ls_parse_folders']='fileom_ls_parse_folders'

fileom_ls_parse_links() {
    local PAGE=$1
    local LINKS

    LINKS=$(parse_all_attr_quiet 'target="_blank">http://fileom.com' 'href' <<< "$PAGE")

    echo "$LINKS"
}

fileom_ls_parse_names() {
    local PAGE=$1
    local NAMES

    NAMES=$(parse_all_quiet 'target="_blank">http://fileom.com' 'target="_blank">\([^<]\+\)' -2 <<< "$PAGE")

    echo "$NAMES"
}

fileom_ls_parse_folders() {
    local PAGE=$1
    local FOLDERS

    FOLDERS=$(parse_all_quiet 'folder2.gif' 'href="\([^"]\+\)' 2 <<< "$PAGE") || return

    echo "$FOLDERS"
}
