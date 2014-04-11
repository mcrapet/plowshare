#!/bin/bash
#
# nosupload callbacks
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

xfcb_nosupload_ul_get_space_data() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE SPACE_USED SPACE_LIMIT

    PAGE=$(curl -b 'lang=english' -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    # XXX Kb of XXX GB
    SPACE_USED=$(parse 'Used space' '<b>*\([0-9.]\+[[:space:]]*[KMGBb]\+\?\)</b> of ' \
        <<< "$PAGE") || return

    SPACE_LIMIT=$(parse 'Used space' 'of <b>\([0-9.]\+[[:space:]]*[KMGBb]\+\)</b>' \
        <<< "$PAGE") || return

    echo "$SPACE_USED"
    echo "$SPACE_LIMIT"
}
