#!/bin/bash
#
# mirorii.com module
# Copyright (c) 2012-2013 Plowshare team
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

MODULE_MIRORII_REGEXP_URL='http://\(www\.\)\?mirorii\.com/'

MODULE_MIRORII_UPLOAD_OPTIONS="
DESCRIPTION,d,description,S=DESCRIPTION,Set file description"
MODULE_MIRORII_UPLOAD_REMOTE_SUPPORT=no

MODULE_MIRORII_LIST_OPTIONS=""

# Upload a file to Mirorii
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: mirorii.com download link
mirorii_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://www.mirorii.com'
    local PAGE FORM_HTML FORM_ACTION FORM_REMOTE FORM_FILES FORM_SITES
    local SITES_ALL_VALUE SITES_ALL_ID SITES_SEL_VALUE SITES_SEL_ID

    PAGE=$(curl "$BASE_URL" | break_html_lines) || return
    FORM_HTML=$(grep_form_by_id "$PAGE" F1) || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_REMOTE=$(echo "$FORM_HTML" | parse_form_input_by_name 'remote') || return
    FORM_FILES=$(echo "$FORM_HTML" | parse_form_input_by_name 'files') || return

    # Retrieve complete hosting site list
    SITES_ALL_VALUE=$(echo "$FORM_HTML" | parse_all_attr '[[:space:]]name=.site.[[:space:]]' value)
    SITES_ALL_ID=$(echo "$FORM_HTML" | parse_all_attr '[[:space:]]name=.site.[[:space:]]' id)

    if [ -z "$SITES_ALL_ID" ]; then
        log_error 'Empty list, site updated?'
        return $ERR_FATAL
    else
        log_debug "Available sites:" $SITES_ALL_ID
    fi

    # Default hosting sites selection
    SITES_SEL_VALUE=$(echo "$FORM_HTML" | parse_all_attr '[[:space:]]checked[[:space:]]' value)
    SITES_SEL_ID=$(echo "$FORM_HTML" | parse_all_attr '[[:space:]]checked[[:space:]]' id)

    if [ -z "$SITES_SEL_ID" ]; then
        log_debug 'Empty site selection. Nowhere to upload!'
        return $ERR_FATAL
    fi

    log_debug "Selected sites:" $SITES_SEL_ID

    FORM_SITES=""
    while read LINE; do
        FORM_SITES="$FORM_SITES -F site=$LINE"
    done <<< "$SITES_SEL_VALUE"

    PAGE=$(curl_with_log -L -F "files=$FORM_FILES" -F "remote=$FORM_REMOTE" \
        -F "file1=@$FILE;filename=$DESTFILE" \
        --form-string "description1=$DESCRIPTION" \
        --form-string 'links=' \
        $FORM_SITES "$FORM_ACTION" | break_html_lines) || return

    echo "$PAGE" | parse '>Fichier' "href=.\([^'\"]*\)" 1
}

# List links from a Mirorii link
# $1: mirorii link
# $2: recurse subfolders (ignored here)
# stdout: list of links
mirorii_list() {
    local -r URL=$1
    local PAGE LINKS LINK

    if test "$2"; then
        log_error 'Recursive flag has no sense here, abort'
        return $ERR_BAD_COMMAND_LINE
    fi

    PAGE=$(curl "$URL") || return
    LINKS=$(echo "$PAGE" | parse_all_tag 'www\.mirorii\.com/.*_blank' a)

    while read SITE_URL; do
        PAGE=$(curl "$SITE_URL") || return
        LINK=$(echo "$PAGE" | parse_attr 'frame' src)

        # Referer mandatory here
        #PAGE=$(curl --referer "$SITE_URL" "$LINK") || return
        PAGE=$(curl --referer "$LINK" "$SITE_URL") || return

        LINK=$(echo "$PAGE" | parse_attr 'scrolling=' src)
        if match_remote_url "$LINK"; then
            echo "$LINK"
            echo
        fi
    done <<< "$LINKS"
}
