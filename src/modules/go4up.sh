#!/bin/bash
#
# go4up.com module
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

MODULE_GO4UP_REGEXP_URL="http://\(www\.\)\?go4up\.com"

MODULE_GO4UP_UPLOAD_OPTIONS=""
MODULE_GO4UP_UPLOAD_REMOTE_SUPPORT=no

MODULE_GO4UP_LIST_OPTIONS=""

# Upload a file to go4up.com
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: go4up.com download link
go4up_upload() {
    eval "$(process_options go4up "$MODULE_GO4UP_UPLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://go4up.com'

    # Registered users can use public API:
    # http://go4up.com/wiki/index.php/API_doc

    local PAGE UPLOAD_URL1 UPLOAD_URL2 FORM_HTML FORM_UID HOST_LIST UPLOAD_ID

    # Site uses UberUpload
    PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL") || return

    UPLOAD_URL1=$(echo "$PAGE" | \
        parse 'path_to_link_script' '"\([^"]\+\)"') || return
    UPLOAD_URL2=$(echo "$PAGE" | \
        parse 'path_to_upload_script' '"\([^"]\+\)"') || return

    FORM_HTML=$(grep_form_by_name "$PAGE" 'ubr_upload_form') || return
    FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id_user') || return

    # Get (default) host list
    HOST_LIST=$(echo "$FORM_HTML" | \
        parse_all_attr '[[:space:]]checked[[:space:]]' 'value') || return

    local HOST_FORM_STRING1 HOST_FORM_STRING2 HOST
    while read HOST; do
        log_debug "selected site: $HOST"
        HOST_FORM_STRING1="$HOST_FORM_STRING1 -d box%5B%5D=$HOST"
        HOST_FORM_STRING2="$HOST_FORM_STRING2 -F box[]=$HOST"
    done <<< "$HOST_LIST"

    PAGE=$(curl -b "$COOKIE_FILE" \
        --referer "$BASE_URL/index.php" \
        $HOST_FORM_STRING1 \
        -d "id_user=$FORM_UID" \
        -d "upload_file[]=$DESTFILE" \
        "$BASE_URL$UPLOAD_URL1") || return

    # if(typeof UberUpload.startUpload == 'function')
    # { UberUpload.startUpload("f7c3511c7eac0716dc64bba7e32ef063",0,0); }
    UPLOAD_ID=$(echo "$PAGE" | parse 'startUpload(' '"\([^"]\+\)"') || return
    log_debug "id: $UPLOAD_ID"

    # Note: No need to call ubr_set_progress.php, ubr_get_progress.php

    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        --referer "$BASE_URL/index.php" \
        -F "id_user=$FORM_UID" \
        -F "upfile_$(date +%s)000=@$FILE;filename=$DESTFILE" \
        $HOST_FORM_STRING2 \
        "$BASE_URL$UPLOAD_URL2?upload_id=$UPLOAD_ID") || return

    # parent.UberUpload.redirectAfterUpload('../../uploaded.php?upload_id=9f07...
    UPLOAD_URL1=$(echo "$PAGE" | \
        parse 'redirectAfter' "'\.\.\/\.\.\([^']\+\)'") || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        --referer "$BASE_URL/index.php" \
        "$BASE_URL$UPLOAD_URL1") || return

    echo "$PAGE" | parse_attr '\/dl\/' href || return
}

# List links from a go4up link
# $1: go4up link
# $2: recurse subfolders (ignored here)
# stdout: list of links
go4up_list() {
    local URL=$1
    local PAGE LINKS SITE_URL

    test "$2" && log_debug "recursive flag specified but has no sense here, ignore it"

    PAGE=$(curl -L "$URL") || return

    if match 'The file is being uploaded on mirror websites' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'does not exist or has been removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    LINKS=$(echo "$PAGE" | parse_all_tag_quiet 'class="dl"' a) || return
    if [ -z "$LINKS" ]; then
        log_error 'No links found. Site updated?'
        return $ERR_FATAL
    fi

    #  Print links (stdout)
    while read SITE_URL; do
        test "$SITE_URL" || continue

        # <meta http-equiv="REFRESH" content="0;url=http://..."></HEAD>
        PAGE=$(curl "$SITE_URL") || return
        echo "$PAGE" | parse 'http-equiv' 'url=\([^">]\+\)'
    done <<< "$LINKS"
}
