#!/bin/bash
#
# vidspot callbacks
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

declare -gA VIDSPOT_FUNCS
VIDSPOT_FUNCS['dl_parse_form1']='vidspot_dl_parse_form1'
VIDSPOT_FUNCS['dl_commit_step1']='vidspot_dl_commit_step1'
VIDSPOT_FUNCS['dl_parse_imagehosting']='vidspot_dl_parse_imagehosting'

vidspot_dl_parse_form1() {
    local -r PAGE=$1

    local EMBED_URL FILE_NAME

    # For http://vidspot.net/2/v-XXXXXX links
    if match '<iframe.*builtin-' "$PAGE"; then
        FILE_NAME=$(parse_tag 'h3' <<< "$PAGE") || return
        FILE_NAME=$(strip <<< "$FILE_NAME")

        EMBED_URL=$(parse_attr 'iframe' 'src' <<< "$PAGE") || return

        echo "name=$FILE_NAME.mp4"
        echo "$EMBED_URL"
    else
        xfilesharing_dl_parse_form1_generic "$@"
    fi
}

vidspot_dl_commit_step1() {
    local -r COOKIE_FILE=$1
    local -r FORM_ACTION=$2
    local -r FORM_DATA=$3

    local EMBED_URL

    {
    read -r
    read -r EMBED_URL
    } <<<"$FORM_DATA"

    if [ "$EMBED_URL" = 'op=download1' ]; then
        xfilesharing_dl_commit_step1_generic "$@"
    else
        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
            -e "$FORM_ACTION" \
            "$EMBED_URL") || return

        echo "$PAGE"
    fi
}

# Ignore video thumbnail
vidspot_dl_parse_imagehosting() {
    return 1
}
