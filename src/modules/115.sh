#!/bin/bash
#
# 115.com module
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

MODULE_115_REGEXP_URL="http://\(\w\+\.\)\?115\.com/file/"

MODULE_115_DOWNLOAD_OPTIONS=""
MODULE_115_DOWNLOAD_RESUME=no
MODULE_115_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

# Output a 115.com file download URL
# $1: cookie file (unused here)
# $2: 115.com url
# stdout: real file download link
115_download() {
    local HTML_PAGE=$(curl -L "$2" | break_html_lines)

    if match 'file-notfound"' "$HTML_PAGE"; then
        log_debug "file not found"
        return $ERR_LINK_DEAD
    fi

    local LINKS=$(echo "$HTML_PAGE" | parse_all_attr 'ds_url' 'href')

    if [ -z "$LINKS" ]; then
        log_error "no link found, site updated?"
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # There are usually mirrors (do a HTTP HEAD request to check dead mirror)
    while read URL; do
        HEADERS=$(curl -I "$URL")

        local FILENAME=$(echo "$HEADERS" | grep_http_header_content_disposition)
        if [ -n "$FILENAME" ]; then
            echo "$URL"

            if [ "${#FILENAME}" -ge 255 ]; then
                FILENAME="${FILENAME:0:254}"
                log_debug "filename is too long, truncating it"
            fi

            echo "$FILENAME"
            return 0
        fi

        local DIRECT=$(echo "$HEADERS" | grep_http_header_content_type)
        if [ "$DIRECT" = 'application/octet-stream' ]; then
            echo "$URL"
            return 0
        fi
    done <<< "$LINKS"

    log_debug "all mirrors are dead"
    return 1
}
