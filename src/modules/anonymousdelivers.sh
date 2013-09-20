#!/bin/bash
#
# anonymousdelivers.us module
# Copyright (c) 2013 Plowshare team
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

MODULE_ANONYMOUSDELIVERS_REGEXP_URL='http://\(www\.\)\?anonymousdelivers\.us/'

MODULE_ANONYMOUSDELIVERS_DOWNLOAD_OPTIONS=""
MODULE_ANONYMOUSDELIVERS_DOWNLOAD_RESUME=yes
MODULE_ANONYMOUSDELIVERS_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_ANONYMOUSDELIVERS_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_ANONYMOUSDELIVERS_UPLOAD_OPTIONS="
PRIVATE_FILE,,private,,Add checksum in final link"
MODULE_ANONYMOUSDELIVERS_UPLOAD_REMOTE_SUPPORT=no

# Output an anonymousdelivers.us file download URL
# $1: cookie file (unsued here)
# $2: anonymousdelivers.us url
# stdout: real file download link
anonymousdelivers_download() {
    local -r URL=$2
    local PAGE FILE_URL FILENAME

    PAGE=$(curl "$URL") || return

    FILE_URL=$(parse_attr 'download_image' href <<< "$PAGE") || return
    FILENAME=$(parse 'Name[[:space:]]*</td>' \
        '^[[:space:]]*\(.*\)[[:space:]]*</td>' 2 <<< "$PAGE")

    echo "http://anonymousdelivers.us$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to anonymousdelivers.us
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
anonymousdelivers_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://anonymousdelivers.us/upload'

    PAGE=$(curl_with_log -L \
        -F "userfile=@$FILE;filename=$DESTFILE" \
        ${PRIVATE_FILE:+-F 'private=1'} \
        "$BASE_URL") || return

    parse 'class=.link.>' '[[:space:]]*\(http://[^[:space:]<]\+\)' 1 <<< "$PAGE"
}
