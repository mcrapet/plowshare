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

backin_dl_parse_countdown () {
    local -r PAGE=$1
    local WAIT_TIME
    
    WAIT_TIME=$(echo "$PAGE" | parse 'setTimeout("azz()"' 'setTimeout("azz()", \([0-9]\+\)\*1000);') || return
    (( WAIT_TIME++ ))
    
    echo "$WAIT_TIME"
}
