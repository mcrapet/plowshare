#!/bin/bash
#
# humyo.com module
# Copyright (c) 2010 Plowshare team
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
MODULE_HUMYO_DOWNLOAD_CONTINUE=no

# Output a humyo file download URL
#
# $1: A humyo URL
#
humyo_download() {
    eval "$(process_options humyo "$MODULE_HUMYO_DOWNLOAD_OPTIONS" "$@")"

    BASEURL="http://www.humyo.com"
    URL=$1

    # test for direct download links
    FILENAME=$(curl -I "$1" | grep_http_header_content_disposition) || true
    test "$FILENAME" && {
        test "$CHECK_LINK" && return 255

        echo $URL
        echo $FILENAME
        return 0
    }

    PAGE=$(curl "$URL")
    matchi "<h1>File Not Found</h1>" "$PAGE" &&
        { log_debug "file not found"; return 254; }

    FILE_URL=$(echo "$PAGE" | break_html_lines| \
               parse_attr 'Download this \(file\|image\|photo\)' 'href') ||
        { log_error "download link not found"; return 1; }

    test "$CHECK_LINK" && return 255

    echo "${BASEURL}${FILE_URL}"
}
