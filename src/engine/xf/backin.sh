#!/bin/bash
#
# backin callbacks
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

declare -gA BACKIN_FUNCS
BACKIN_FUNCS['dl_parse_countdown']='backin_dl_parse_countdown'
BACKIN_FUNCS['pr_parse_file_name']='backin_pr_parse_file_name'
BACKIN_FUNCS['pr_parse_file_size']='backin_pr_parse_file_size'

backin_dl_parse_countdown () {
    local -r PAGE=$1
    local WAIT_TIME

    WAIT_TIME=$(parse_quiet 'setTimeout("azz()"' 'setTimeout("azz()", \([0-9]\+\)\*1000);' <<< "$PAGE")

    echo "$WAIT_TIME"
}

backin_pr_parse_file_name() {
    local -r PAGE=$1
    local FILE_NAME

    FILE_NAME=$(parse_quiet '^<h2 class="textdown"> ' '> \(.*\)$' <<< "$PAGE")

    echo "$FILE_NAME"
}

backin_pr_parse_file_size() {
    local -r PAGE=$1
    local FILE_SIZE

    FILE_SIZE=$(parse_quiet '^<span class="textdown">' '>\([^<]\+\)' <<< "$PAGE")

    echo "$FILE_SIZE"
}
