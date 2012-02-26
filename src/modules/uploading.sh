#!/bin/bash
#
# uploading.com module
# Copyright (c) 2010-2011 Plowshare team
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

MODULE_UPLOADING_REGEXP_URL="http://\(\w\+\.\)\?uploading\.com/"

MODULE_UPLOADING_DOWNLOAD_OPTIONS=""
MODULE_UPLOADING_DOWNLOAD_RESUME=no
MODULE_UPLOADING_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

# Output a uploading file download URL (anonymous)
# $1: cookie file
# $2: uploading.com url
# stdout: real file download link
uploading_download() {
    eval "$(process_options uploading "$MODULE_UPLOADING_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://uploading.com'
    local DATA ERR1 ERR2 WAIT JSURL FILENAME FILE_URL

    # Force language to English
    DATA=$(curl -c "$COOKIEFILE" -b "lang=1" "$URL") || return

    if match "requested file is not found" "$DATA"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    ERR1="Your IP address.*file"
    ERR2="Sorry, you have reached your daily download limit."
    if match "$ERR1\|$ERR2" "$DATA"; then
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match "<h2.*Download Limit.*</h2>" "$DATA"; then
        log_debug "Server asked to wait"
        WAIT=$(echo "$DATA" | parse "download only one" "one file per \([[:digit:]]\+\) minute")
        test -n "$WAIT" && echo $((WAIT*60))
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match '<h2>File is still uploading</h2>' "$DATA"; then
        log_debug "file is still uploading"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    local FORM_HTML FORM_URL FORM_FID FORM_CODE
    FORM_HTML=$(grep_form_by_id "$DATA" 'downloadform')
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_FID=$(echo "$FORM_HTML" | parse_form_input_by_name 'file_id')
    FORM_CODE=$(echo "$FORM_HTML" | parse_form_input_by_name 'code')

    DATA=$(curl -b "$COOKIEFILE" -b "lang=1" --data \
        "action=second_page&file_id=${FORM_FID}&code=$FORM_CODE" "$FORM_URL") || return

    WAIT=$(echo "$DATA" | parse_quiet 'start_timer([[:digit:]]\+)' \
        'start_timer(\([[:digit:]]\+\))')
    test -z "$WAIT" && WAIT=$(echo "$DATA" | parse 'var[[:space:]]*timer_count' \
        'timer_count[[:space:]]*=[[:space:]]*\([[:digit:]]\+\);')

    if test -z "$WAIT"; then
        log_error "Cannot get wait time"
        return $ERR_FATAL
    fi

    JSURL="$BASE_URL/files/get/?JsHttpRequest=$(date +%s000)-xml"
    FILENAME=$(echo "$DATA" | parse_quiet '<title>' \
        '<title>Download \(.*\) for free on uploading.com<\/title>')

    # Second attempt (note: filename might be truncated in the page)
    test -z "$FILENAME" &&
        FILENAME=$(echo "$DATA" | grep 'File size'  | strip | parse . '^\([^ 	]*\)')

    wait $WAIT seconds || return

    DATA=$(curl -b "$COOKIEFILE" --data \
        "action=get_link&file_id=${FORM_FID}&code=${FORM_CODE}&pass=undefined" "$JSURL") || return

    # Example of answer:
    # { "id": "1268521606000", "js": { "answer": { "link": "http:\/\/up3.uploading.com\/get_file\/%3D%3DwARfyFZ3fKB8rJ ... " } }, "text": "" }
    FILE_URL=$(echo "$DATA" | parse '"answer":' '"link":[[:space:]]*"\([^"]*\)"') || return

    echo "$FILE_URL"
    echo "$FILENAME"
}
