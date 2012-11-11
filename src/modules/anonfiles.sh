#!/bin/bash
#
# anonfiles.com module
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

MODULE_ANONFILES_REGEXP_URL="https\?://\([[:alnum:]]\+\.\)\?anonfiles\.com/"

MODULE_ANONFILES_DOWNLOAD_OPTIONS=""
MODULE_ANONFILES_DOWNLOAD_RESUME=yes
MODULE_ANONFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_ANONFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_ANONFILES_UPLOAD_OPTIONS=""
MODULE_ANONFILES_UPLOAD_REMOTE_SUPPORT=no

# Output an AnonFiles.com file download URL
# $1: cookie file (unsued here)
# $2: anonfiles url
# stdout: real file download link
anonfiles_download() {
    local -r URL=$2
    local PAGE FILE_URL FILENAME

    PAGE=$(curl "$URL") || return

    FILE_URL=$(echo "$PAGE" | parse_attr_quiet 'download_button' href)

    if [ -z "$FILE_URL" ]; then
        FILE_URL=$(echo "$PAGE" | \
            parse_attr_quiet 'image_preview' src) || return
    fi

    test "$CHECK_LINK" && return 0

    FILENAME=$(echo "$PAGE" | parse_tag '<legend' b)

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to AnonFiles.com
# Use API: https://anonfiles.com/api/help
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download
anonfiles_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='https://anonfiles.com/api'
    local JSON DL_URL ERR MSG

    # Note1: Accepted file typs is very restrictive!
    # Note2: -F "file_publish=on" does not work!
    JSON=$(curl_with_log \
        -F "file=@$FILE;filename=$DESTFILE" "$BASE_URL") || return

    DL_URL=$(echo "$JSON" | parse_json_quiet url)
    if match_remote_url "$DL_URL"; then
      echo "$DL_URL"
      return 0
    fi

    ERR=$(echo "$JSON" | parse_json status)
    MSG=$(echo "$JSON" | parse_json msg)
    log_error "Unexpected status ($ERR): $MSG"
    return $ERR_FATAL
}
