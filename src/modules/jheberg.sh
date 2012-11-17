#!/bin/bash
#
# jheberg.net module
# Copyright (c) 2012 Plowshare team
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

MODULE_JHEBERG_REGEXP_URL="http://www\.jheberg\.net/"

MODULE_JHEBERG_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_JHEBERG_UPLOAD_REMOTE_SUPPORT=no

MODULE_JHEBERG_LIST_OPTIONS=""

# Upload a file to Jheberg.net
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: jheberg.net download link
jheberg_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r API_URL='http://www.jheberg.net/api/'
    local PAGE UPLOAD_URL JSON USER PASSWORD

    # Note: official API does not allow hoster selection (yet).

    PAGE=$(curl "$API_URL/") || return
    UPLOAD_URL=$(echo "$PAGE" | parse_tag 'apiUploadUrl' pre) || return
    log_debug "Upload URL: $UPLOAD_URL"

    if [ -n "$AUTH" ]; then
        split_auth "$AUTH" USER PASSWORD || return
        JSON=$(curl -F "file=@$FILE;filename=$DESTFILE" \
            -F "username=$USER" -F "password=$PASSWORD" \
            "$UPLOAD_URL") || return
    else
        JSON=$(curl -F "file=@$FILE;filename=$DESTFILE" \
            "$UPLOAD_URL") || return
    fi

    if match_json_true 'error' "$JSON"; then
        local ERR=$(echo "$JSON" | parse_json 'error_string')
        if matchi 'bad credentials' "$ERR"; then
            return $ERR_LOGIN_FAILED
        else
            log_error "Remote error: $ERR"
            return $ERR_FATAL
        fi
    fi

    echo "$JSON" | parse_json 'url' || return
}

# List links from a Jheberg link
# $1: jheberg link
# $2: recurse subfolders (ignored here)
# stdout: list of links
jheberg_list() {
    local -r URL=$1
    local -r BASE_URL='http://www.jheberg.net'
    local JSON PAGE URL2 LINKS NAMES REL_URL

    if test "$2"; then
        log_error "Recursive flag has no sense here, abort"
        return $ERR_BAD_COMMAND_LINE
    fi

    JSON=$(curl --get --data "id=$(uri_encode_strict <<< "$URL")" \
        "$BASE_URL/api/check-link") || return

    if [ -z "$JSON" ]; then
        return $ERR_LINK_DEAD
    fi

    PAGE=$(curl "$URL") || return
    URL2=$(echo "$PAGE" | parse_attr liendownload href) || return

    # Note: HTTP referer is chekced
    PAGE=$(curl --referer "$URL" "$BASE_URL$URL2") || return

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet '/redirect/' href) || return
    if [ -z "$LINKS" ]; then
        return $ERR_LINK_DEAD
    fi

    NAMES=( $(echo "$PAGE" | parse_all_attr '/redirect/' id) )

    while read REL_URL; do
        test "$REL_URL" || continue

        IFS='/' read DL_ID HOSTER <<< "${REL_URL:10}"

        JSON=$(curl --referer "$BASE_URL$REL_URL" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -F "slug=$DL_ID" -F "host=$HOSTER"    \
            "$BASE_URL/redirect-ajax/") || return

        URL2=$(echo "$JSON" | parse_json url)
        if match_remote_url "$URL2"; then
            echo "$URL2"
            echo "${NAMES[0]}"
        fi

        # Drop first element
        NAMES=("${NAMES[@]:1}")
    done <<< "$LINKS"
}
