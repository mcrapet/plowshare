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

declare -gA UPTOBOX_FUNCS
UPTOBOX_FUNCS['ul_get_space_data']='uptobox_ul_get_space_data'

uptobox_ul_get_space_data() {
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
