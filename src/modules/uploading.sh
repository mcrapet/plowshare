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
    COOKIES=$(tempfile)
    while true; do
        FIRST_PAGE=$(curl "$URL")
        WAIT_URL=$(echo "$FIRST_PAGE" | parse '<form.*id="downloadform"' 'action="\([^"]*\)"' 2>/dev/null) ||
            { error "file not found"; return 254; }
        test "$CHECK_LINK" && return 255
        FILE_ID=$(echo "$FIRST_PAGE" | parse 'input.*name="file_id"' 'value="\([^"]*\)"') ||
            { error "can't get file_id"; return 1; }
        DATA=$(curl -c $COOKIES --data "action=second_page&file_id=$FILE_ID" "$WAIT_URL") ||
            { error "can't get wait URL contents"; return 1; }

        ERR_ALREADY="Your IP address.*file"
        if echo "$DATA" | grep -o "$ERR_ALREADY" >&2; then
            countdown 60 10 seconds 60
            continue
        fi
        break
    done

    WAIT=$(echo "$DATA" | parse 'start_timer([[:digit:]]\+)' 'start_timer(\(.*\))')
    JSURL="$BASE_URL/files/get/?JsHttpRequest=$(date +%s000)-xml"
    countdown $WAIT 10 seconds 1
    FILENAME=$(echo "$DATA" | grep -A1 ico_big_download_file.gif | tail -n1 | parse h2 '<h2>\([^<]*\)')
    DATA=$(curl -b $COOKIES --data "action=get_link&file_id=$FILE_ID&pass=undefined" "$JSURL") ||
        { error "can't get link"; return 1; }
    FILE_URL=$(echo $DATA | parse '"answer":' '"link": "\([^"]*\)"') ||
        { error "URL not found"; return 1; }
    echo $FILE_URL
    echo $FILENAME
    echo $COOKIES
}
