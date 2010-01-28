#!/bin/bash
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
#
BASE_URL="http://uploading.com"
MODULE_UPLOADING_REGEXP_URL="http://\(\w\+\.\)\?uploading.com/"
MODULE_UPLOADING_DOWNLOAD_OPTIONS=""
MODULE_UPLOADING_UPLOAD_OPTIONS=""
MODULE_UPLOADING_DOWNLOAD_CONTINUE=no

# Output a uploading file download URL (anonymous, NOT PREMIUM)
#
# uploading_download UPLOADING_URL
#
uploading_download() {
    set -e
    eval "$(process_options uploading "$MODULE_UPLOADING_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    COOKIES=$(create_tempfile)

    while retry_limit_not_reached || return 3; do
        # Force language to English
        DATA=$(curl --cookie-jar "$COOKIES" --cookie "lang=1" "$URL")
        ERR1="Your IP address.*file"
        ERR2="Sorry, you have reached your daily download limit."
        if echo "$DATA" | grep -o "$ERR1\|$ERR2" >&2; then
            WAITTIME=1
            countdown $WAITTIME 1 minutes 60 || return 2
            continue
        fi

        match "requested file is not found" "$DATA" && return 254
        	
        if match "<h2.*Download Limit.*</h2>" "$DATA"; then
            test "$CHECK_LINK" && return 255
            WAIT=$(echo "$DATA" | parse "download only one" "one file per \([[:digit:]]\+\) minute") ||
                WAIT=5
            debug "Server asked to wait"
            countdown $WAIT 1 minutes 60
            continue
        fi 
        WAIT_URL=$(echo "$DATA" | parse '<form.*id="downloadform"' 'action="\([^"]*\)"' 2>/dev/null) ||
            { error "file not found"; return 1; }
        test "$CHECK_LINK" && return 255
        FILE_ID=$(echo "$DATA" | parse 'input.*name="file_id"' 'value="\([^"]*\)"') ||
            { error "can't get file_id"; return 1; }
        DATA=$(curl --cookie "$COOKIES" --cookie "lang=1" --data "action=second_page&file_id=$FILE_ID" "$WAIT_URL") ||
            { error "can't get wait URL contents"; return 1; }
        break
    done

    WAIT=$(echo "$DATA" | parse 'start_timer([[:digit:]]\+)' 'start_timer(\(.*\))')
    JSURL="$BASE_URL/files/get/?JsHttpRequest=$(date +%s000)-xml"

    FILENAME=$(echo "$DATA" | 
        parse '<title>' '<title>Download \(.*\) for free on uploading.com<\/title>' 2>/dev/null)

    # second attempt (note: filename might be truncated in the page)
    test -z "$FILENAME" &&
        FILENAME=$(echo "$DATA" | grep -A1 ico_big_download_file.gif | tail -n1 | parse 'h2' '<h2>\([^<]*\)')

    countdown $WAIT 10 seconds 1 || return 2

    DATA=$(curl --cookie "$COOKIES" --data "action=get_link&file_id=$FILE_ID&pass=undefined" "$JSURL") ||
        { error "can't get link"; return 1; }

    # example of answer:
    # { "id": "1268521606000", "js": { "answer": { "link": "http:\/\/up3.uploading.com\/get_file\/%3D%3DwARfyFZ3fKB8rJ ... " } }, "text": "" }
    FILE_URL=$(echo "$DATA" | parse '"answer":' '"link": "\([^"]*\)"') ||
        { error "URL not found"; return 1; }

    echo $FILE_URL
    echo $FILENAME
    echo $COOKIES
}
