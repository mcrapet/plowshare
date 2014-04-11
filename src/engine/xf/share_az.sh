#!/bin/bash
#
# share_az callbacks
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

xfcb_share_az_ls_parse_links() {
    local PAGE=$1
    local LINKS

    LINKS=$(parse_all_attr_quiet '<p class="link5">' 'href' <<< "$PAGE")

    echo "$LINKS"
}

xfcb_share_az_ls_parse_names() {
    local PAGE=$1
    local NAMES

    NAMES=$(parse_all_tag_quiet '<p class="link5">' 'a' <<< "$PAGE")

    echo "$NAMES"
}
