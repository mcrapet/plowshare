#!/bin/bash
#
# uploading.com module
# Copyright (c) 2010-2012 Plowshare team
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

MODULE_UPLOADING_REGEXP_URL="http://\([[:alnum:]]\+\.\)\?uploading\.com/"

MODULE_UPLOADING_DOWNLOAD_OPTIONS=""
MODULE_UPLOADING_DOWNLOAD_RESUME=no
MODULE_UPLOADING_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

# Output a uploading file download URL (anonymous)
# $1: cookie file
# $2: uploading.com url
# stdout: real file download link
uploading_download() {
    eval "$(process_options uploading "$MODULE_UPLOADING_DOWNLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local URL=$2
    local BASE_URL='http://uploading.com'
    local PAGE WAIT CODE PASS JSON FILENAME FILE_URL

    # Force language to English
    PAGE=$(curl -c "$COOKIE_FILE" -b "lang=1" "$URL") || return

    # <h2>OOPS! Looks like file not found.</h2>
    if match 'file not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # <h2>Maximum File Size Limit</h2>
    if matchi 'File Size Limit' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS

    # <h2>Parallel Download</h2>
    elif match '[Yy]our IP address is currently' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE

    # <h2>Daily Download Limit</h2>
    elif matchi 'daily download limit' "$PAGE"; then
        echo 600
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    CODE=$(echo "$PAGE" | parse '[[:space:]]code:' ":[[:space:]]*[\"']\([^'\"]*\)") || return
    PASS=false
    log_debug "code: $CODE"

    FILENAME=$(echo "$PAGE" | parse '<title>' \
        '<title>Download \(.*\) for free on uploading.com</title>')

    # Get wait time
    WAIT=$(echo "$PAGE" | parse_tag '"timer_count"' span) || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d 'action=second_page' -d "code=$CODE" \
        "$BASE_URL/files/get/?ajax") || return

    wait $WAIT || return

    JSON=$(curl -b "$COOKIE_FILE" -d 'action=get_link' \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d "code=$CODE" -d "pass=$PASS" \
        "$BASE_URL/files/get/?ajax") || return

    # {"answer":{"link":"http:\/\/fs53.uploading.com\/get_file\/... "}}
    FILE_URL=$(echo "$JSON" | parse_json link) || return

    echo "$FILE_URL"
    echo "$FILENAME"
}
