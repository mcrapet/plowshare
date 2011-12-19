#!/bin/bash
#
# humyo.com module
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

MODULE_HUMYO_REGEXP_URL="http://\(www\.\)\?humyo\.com/"

MODULE_HUMYO_DOWNLOAD_OPTIONS=""
MODULE_HUMYO_DOWNLOAD_RESUME=no
MODULE_HUMYO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

# Output a humyo file download URL
# $1: cookie file (unused here)
# $2: humyo.com url
# stdout: real file download link
humyo_download() {
    local URL="$2"
    local PAGE FILE_URL FILENAME

    # test for direct download links
    FILENAME=$(curl --head "$URL" | grep_http_header_content_disposition)
    if [ -n "$FILENAME" ]; then
        test "$CHECK_LINK" && return 0
        echo "$URL"
        echo "$FILENAME"
        return 0
    fi

    PAGE=$(curl "$URL" | break_html_lines) || return

    if matchi "<h1>File Not Found</h1>" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr '"lcap"' 'href') || return

    test "$CHECK_LINK" && return 0

    echo "$FILE_URL"
}
