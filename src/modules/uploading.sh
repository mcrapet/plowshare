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
MODULE_UPLOADING_DOWNLOAD_CONTINUE=no

# Output a uploading file download URL (anonymous, NOT PREMIUM)
#
# uploading_download UPLOADING_URL
#
uploading_download() {
    set -e
    eval "$(process_options uploading "$MODULE_UPLOADING_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    BASE_URL="http://uploading.com"
    COOKIES=$(create_tempfile)

    while retry_limit_not_reached || return 3; do
        # Force language to English
        DATA=$(curl --cookie-jar "$COOKIES" --cookie "lang=1" "$URL")
        ERR1="Your IP address.*file"
        ERR2="Sorry, you have reached your daily download limit."
        if match "$ERR1\|$ERR2" "$DATA"; then
            WAITTIME=1
            wait $WAITTIME minutes || return 2
            continue
        fi

        match "requested file is not found" "$DATA" && return 254

        if match "<h2.*Download Limit.*</h2>" "$DATA"; then
            if test "$CHECK_LINK"; then
                rm -f $COOKIES
                return 255
            fi

            WAIT=$(echo "$DATA" | parse "download only one" "one file per \([[:digit:]]\+\) minute") ||
                WAIT=5
            log_debug "Server asked to wait"
            wait $WAIT minutes || return 2
            continue
        fi

        HTML_FORM=$(grep_form_by_id "$DATA" 'downloadform')
        WAIT_URL=$(echo "$HTML_FORM" | parse_form_action) ||
            { log_error "can't get wait url"; return 1; }

        if test "$CHECK_LINK"; then
            rm -f $COOKIES
            return 255
        fi

        FILE_ID=$(echo "$HTML_FORM" | parse_form_input_by_name 'file_id') ||
            { log_error "can't get file_id form field"; return 1; }
        CODE=$(echo "$HTML_FORM" | parse_form_input_by_name 'code') ||
            { log_error "can't get code form field"; return 1; }

        DATA=$(curl --cookie "$COOKIES" --cookie "lang=1" --data "action=second_page&file_id=${FILE_ID}&code=${CODE}" "$WAIT_URL") ||
            { log_error "can't get wait URL contents"; return 1; }
        break
    done

    WAIT=$(echo "$DATA" | parse_quiet 'start_timer([[:digit:]]\+)' \
           'start_timer(\([[:digit:]]\+\))')
    test -z "$WAIT" &&
      WAIT=$(echo "$DATA" | parse 'var[[:space:]]*timer_count' \
             'timer_count[[:space:]]*=[[:space:]]*\([[:digit:]]\+\);')

    test "$WAIT" || { log_error "Cannot get wait time"; return 1; }
    JSURL="$BASE_URL/files/get/?JsHttpRequest=$(date +%s000)-xml"

    FILENAME=$(echo "$DATA" |
        parse '<title>' '<title>Download \(.*\) for free on uploading.com<\/title>' 2>/dev/null)

    # second attempt (note: filename might be truncated in the page)
    test -z "$FILENAME" &&
        FILENAME=$(echo "$DATA" | grep -A1 ico_big_download_file.gif | tail -n1 | parse 'h2' '<h2>\([^<]*\)')

    wait $WAIT seconds || return 2

    DATA=$(curl --cookie "$COOKIES" --data "action=get_link&file_id=${FILE_ID}&code=${CODE}&pass=undefined" "$JSURL") ||
        { log_error "can't get link"; return 1; }

    # example of answer:
    # { "id": "1268521606000", "js": { "answer": { "link": "http:\/\/up3.uploading.com\/get_file\/%3D%3DwARfyFZ3fKB8rJ ... " } }, "text": "" }
    FILE_URL=$(echo "$DATA" | parse '"answer":' '"link":[[:space:]]*"\([^"]*\)"') ||
        { log_error "URL not found"; return 1; }

    echo $FILE_URL
    echo $FILENAME
    echo $COOKIES
}
