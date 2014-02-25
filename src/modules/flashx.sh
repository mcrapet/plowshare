#!/bin/bash
#
# flashx.tv module
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

MODULE_FLASHX_REGEXP_URL='http://\(www\.\)\?flashx\.tv/'

MODULE_FLASHX_DOWNLOAD_OPTIONS=""
MODULE_FLASHX_DOWNLOAD_RESUME=yes
MODULE_FLASHX_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FLASHX_DOWNLOAD_SUCCESSIVE_INTERVAL=
MODULE_FLASHX_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=

MODULE_FLASHX_PROBE_OPTIONS=""

# Output a flashx file download URL
# $1: cookie file
# $2: flashx url
# stdout: real file download link
flashx_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local PAGE CONFIG_URL EMBED_URL FILE_NAME FILE_URL

    PAGE=$(curl -c "$COOKIE_FILE" --location "$URL") || return

    if match 'Video not found, deleted, abused or wrong link\|Video not found, deleted or abused, sorry!' \
       "$PAGE"; then
           return $ERR_LINK_DEAD
    fi

    if match '<h2>404 Error</h2>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(parse_tag '<div class=.video_title' 'div' <<< "$PAGE" | html_to_utf8) || return

    # On main page
    EMBED_URL=$(echo "$PAGE" | parse '<div class="player_container_new"' 'src="\([^"]*\)' 1) || return
    PAGE=$(curl -b "$COOKIE_FILE" "$EMBED_URL") || return

    # Inside iframe embed on main page
    local FORM_HTML FORM_URL FORM_HASH FORM_SEC_HASH
    FORM_HTML=$(grep_form_by_name "$PAGE" 'fxplayit') || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_HASH=$(echo "$FORM_HTML" | parse_form_input_by_name 'hash') || return
    FORM_SEC_HASH=$(echo "$FORM_HTML" | parse_form_input_by_name 'sechash') || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        --referer "$EMBED_URL" \
        --data "hash=$FORM_HASH" \
        --data "sechash=$FORM_SEC_HASH" \
        --header "Cookie: refid=; vr_referrer=" \
        "$(basename_url "$EMBED_URL")/player/$FORM_URL") || return

    # Player's response
    CONFIG_URL=$(echo "$PAGE" | parse '<param name="movie"' 'config=\([^"]*\)') || return
    PAGE=$(curl -b "$COOKIE_FILE" --location "$CONFIG_URL") || return

    # XML config file
    FILE_URL=$(parse_tag 'file' <<< "$PAGE") || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: flashx.tv url
# $3: requested capability list
# stdout: 1 capability per line
flashx_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_NAME

    PAGE=$(curl --location "$URL") || return

    if match 'Video not found, deleted, abused or wrong link\|Video not found, deleted or abused, sorry!' \
       "$PAGE"; then
           return $ERR_LINK_DEAD
    fi

    if match '<h2>404 Error</h2>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse_tag '<div class="video_title"' 'div' <<< "$PAGE" | html_to_utf8) && \
            echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    echo $REQ_OUT
}
