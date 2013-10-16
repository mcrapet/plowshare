#!/bin/bash
#
# imagetwist callbacks
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

declare -gA IMAGETWIST_FUNCS
IMAGETWIST_FUNCS['ls_parse_links']='imagetwist_ls_parse_links'
IMAGETWIST_FUNCS['ls_parse_names']='imagetwist_ls_parse_names'

imagetwist_ls_parse_links() {
    local PAGE=$1
    local LINKS

    LINKS=$(parse_all_attr_quiet '^<TD><a' 'href' <<< "$PAGE")
    LINKS=$(replace '/' 'http://imagetwist.com/' <<< "$LINKS")

    echo "$LINKS"
}

imagetwist_ls_parse_names() {
    return 0
}
