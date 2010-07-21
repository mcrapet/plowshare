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

MODULE_115_REGEXP_URL="http://\(\w\+\.\)\?115\.com/file/"
MODULE_115_DOWNLOAD_OPTIONS=""
MODULE_115_UPLOAD_OPTIONS=
MODULE_115_DOWNLOAD_CONTINUE=no

# Output a 115.com file download URL
#
# $1: A 115.com URL
#
115_download() {
    eval "$(process_options '115' "$MODULE_115_DOWNLOAD_OPTIONS" "$@")"

    HTML_PAGE=$(curl --user-agent 'Mozilla' "$1" | break_html_lines)

    local LINKS=$(echo "$HTML_PAGE" | parse_all 'key1=' 'href="\(http:\/\/[^"]*\)' 2>/dev/null)

    if [ -z "$LINKS" ]; then
        log_debug "file not found"
        return 254
    fi

    test "$CHECK_LINK" && return 255

    # There are usually mirrors (do a HTTP HEAD request to check dead mirror)
    while read FILE_URL; do
        FILE_NAME=$(curl -I "$FILE_URL" | grep_http_header_content_disposition)
        if [ -n "$FILE_NAME" ]; then
            echo "$FILE_URL"
            echo "$FILE_NAME"
            return 0
        fi
    done <<< "$LINKS"

    log_debug "all mirrors are dead"
    return 1
}
