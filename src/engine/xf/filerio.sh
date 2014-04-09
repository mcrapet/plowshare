#!/bin/bash
#
# filerio callbacks
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

xfilesharing:filerio_dl_parse_final_link() {
    local -r PAGE=$1
    #local FILE_NAME=$2

    local FILE_URL JS

    detect_javascript || return

    log_debug 'Decrypting final link...'

    JS=$(echo "$PAGE" | parse '<script type="text/javascript">eval(unescape' ">\(.*\)<") || return

    JS=$(xfilesharing_unpack_js "$JS") || return

    FILE_URL=$(echo "$JS" | parse 'location.href=' 'location.href="\(.*\)"') || return

    echo "$FILE_URL"
}
