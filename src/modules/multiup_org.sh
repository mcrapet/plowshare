#!/bin/bash
#
# multiup.org module
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

MODULE_MULTIUP_ORG_REGEXP_URL='https\?://\(www\.\)\?multiup\.org/'

MODULE_MULTIUP_ORG_LIST_OPTIONS=""
MODULE_MULTIUP_ORG_LIST_HAS_SUBFOLDERS=no

MODULE_MULTIUP_ORG_PROBE_OPTIONS=""

# List links from a multiup.org link
# $1: multiup.org url
# $2: recurse subfolders (ignored here)
# stdout: list of links
multiup_org_list() {
    local -r URL=$(replace '/miror/' '/download/' <<<"$1")
    local -r BASE_URL='http://www.multiup.org'
    local COOKIE_FILE PAGE LINK LINKS NAMES

    # Set-Cookie: PHPSESSID=...; yooclick=true; ...
    COOKIE_FILE=$(create_tempfile) || return
    PAGE=$(curl -L -c "$COOKIE_FILE" "$URL") || return

    LINK=$(parse_quiet 'class=.btn.' 'href=.\([^"]*\)' 1 <<< "$PAGE")
    if [ -z "$LINK" ]; then
        rm -f "$COOKIE_FILE"
        return $ERR_LINK_DEAD
    fi

    PAGE=$(curl -b "$COOKIE_FILE" --referer "$URL" "$BASE_URL$LINK") || return

    rm -f "$COOKIE_FILE"

    LINKS=$(parse_all_quiet 'dateLastChecked=' 'href=.\([^"]*\)' 3 <<< "$PAGE")
    if [ -z "$LINKS" ]; then
        log_error 'No links found. Site updated?'
        return $ERR_FATAL
    fi

    NAMES=$(parse_all_quiet 'dateLastChecked=' 'nameHost=.\([^"]*\)' -2 <<< "$PAGE")

    list_submit "$LINKS" "$NAMES" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: multiup.org url
# $3: requested capability list
# stdout: 1 capability per line
multiup_org_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local JSON REQ_OUT FILE_NAME HASH

    # Notes relatinf to offcial API:
    # - don't provide file size
    # - provides both md5 & sha1
    JSON=$(curl -F "link=$URL" 'http://www.multiup.org/api/check-file') || return

    # {"error":"link is empty"}
    # {"error":"success", ...}
    ERR=$(parse_json error <<< "$JSON") || return
    if [ "$ERR" != 'success' ]; then
        log_debug "Remote error: $ERR"
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse_json 'file_name' <<< "$JSON") && \
            echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *h* ]]; then
        HASH=$(parse_json 'md5_checksum' <<< "$JSON") && \
            echo "$HASH" && REQ_OUT="${REQ_OUT}h"
    fi

    echo $REQ_OUT
}
