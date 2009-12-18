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
MODULE_2SHARED_REGEXP_URL="http://\(www\.\)\?2shared.com/file/"
MODULE_2SHARED_DOWNLOAD_OPTIONS=""
MODULE_2SHARED_UPLOAD_OPTIONS=
MODULE_2SHARED_DOWNLOAD_CONTINUE=yes

# Output a 2shared file download URL
#
# $1: A 2shared URL
#
2shared_download() {
    set -e
    eval "$(process_options 2shared "$MODULE_2SHARED_DOWNLOAD_OPTIONS" "$@")"

    MAIN_PAGE=$(curl --silent "$1")
    FILE_URL=$(echo $MAIN_PAGE | parse 'window.location' 'location = "\([^"]\+\)"' 2>/dev/null)

    test -z "$FILE_URL" &&
        { error "file not found"; return 254; }

    test "$CHECK_LINK" && return 255

    # Try to figure out real name written on page
    FILE_REAL_NAME=$(echo $MAIN_PAGE | parse '<div class="header">' \
		    'header">[[:space:]]*Download[[:space:]]\+\([^ ]\+\)[[:space:]]*' 2>/dev/null)

    echo "$FILE_URL"
    test -n "$FILE_REAL_NAME" &&
        { debug "Filename: $FILE_REAL_NAME"; echo "$FILE_REAL_NAME"; }
}

# Upload a file to 2shared and upload URL (ADMIN_URL)
#
# 2shared_upload FILE [DESTFILE]
#
2shared_upload() {
    set -e
    eval "$(process_options 2shared "$MODULE_2SHARED_UPLOAD_OPTIONS" "$@")"
    FILE=$1
    DESTFILE=${2:-$FILE}
    UPLOADURL="http://www.2shared.com/"

    debug "downloading upload page: $UPLOADURL"
    DATA=$(curl "$UPLOADURL")
    ACTION=$(echo "$DATA" | parse "uploadForm" 'action="\([^"]*\)"') ||
        { debug "cannot get upload form URL"; return 1; }
    COMPLETE=$(echo "$DATA" | parse "uploadComplete" 'location="\([^"]*\)"')
    debug "starting file upload: $FILE"
    STATUS=$(curl \
        -F "mainDC=1" \
        -F "fff=@$FILE;filename=$(basename "$DESTFILE")" \
        "$ACTION")
    match "upload has successfully completed" "$STATUS" ||
        { debug "error on upload"; return 1; }
    DONE=$(curl "$UPLOADURL/$COMPLETE")
    URL=$(echo "$DONE" | parse 'name="downloadLink"' "\(http:[^<]*\)")
    ADMIN=$(echo "$DONE" | parse 'name="adminLink"' "\(http:[^<]*\)")
    echo "$URL ($ADMIN)"
}
