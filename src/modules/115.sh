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
    local URL="$2"
    local PAGE LINKS HEADERS DIRECT FILENAME WAITTIME

    PAGE=$(curl -L "$URL" | break_html_lines) || return

    # FIXME: it is still relevant?
    if match 'file-notfound"' "$PAGE"; then
        log_debug "file not found"
        return $ERR_LINK_DEAD
    fi

    if match 'ico-fail"' "$PAGE"; then
        log_debug "file not alive anymore"
        return $ERR_LINK_DEAD
    fi

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'ds_url' 'href')
    if [ -z "$LINKS" ]; then
        log_error "no link found, site updated?"
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Look for wait time
    WAITTIME=$(echo "$PAGE" | parse_quiet 'id="js_get_download_second"' '">\([^<]\+\)<\/b>')
    log_debug "should wait ${WAITTIME}s"

    # There are usually mirrors (do a HTTP HEAD request to check dead mirror)
    while read URL; do
        HEADERS=$(curl -I "$URL") || return

        FILENAME=$(echo "$HEADERS" | grep_http_header_content_disposition) || return
        if [ -n "$FILENAME" ]; then
            echo "$URL"
            echo "$FILENAME"
            return 0
        fi

        DIRECT=$(echo "$HEADERS" | grep_http_header_content_type) || return
        if [ "$DIRECT" = 'application/octet-stream' ]; then
            echo "$URL"
            return 0
        fi
    done <<< "$LINKS"

    log_debug "all mirrors are dead"
    return $ERR_FATAL
}
