#!/bin/bash
#
# 4shared.com module
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

MODULE_4SHARED_REGEXP_URL="http://\(www\.\)\?4shared\.com/"

MODULE_4SHARED_DOWNLOAD_OPTIONS=""
MODULE_4SHARED_DOWNLOAD_RESUME=no
MODULE_4SHARED_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_4SHARED_LIST_OPTIONS=""

# Output a 4shared file download URL
# $1: cookie file
# $2: 4shared url
# stdout: real file download link
4shared_download() {
    COOKIEFILE="$1"
    URL="$2"

    REAL_URL=$(curl -I "$URL" | grep_http_header_location)
    if test "$REAL_URL"; then
        URL=$REAL_URL
    fi

    PAGE=$(curl -c $COOKIEFILE "$URL")
    if match '4shared\.com\/dir\/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return 1
    elif match 'The file link that you requested is not valid.' "$PAGE"; then
        log_error "File not found!"
        return 254
    fi

    WAIT_URL=$(echo "$PAGE" | parse_attr "4shared\.com\/get\/" 'href')

    test "$CHECK_LINK" && return 0

    WAIT_HTML=$(curl -b $COOKIEFILE "$WAIT_URL")

    WAIT_TIME=$(echo "$WAIT_HTML" | parse 'var c =' \
            "[[:space:]]\([[:digit:]]\+\);")
    FILE_URL=$(echo "$WAIT_HTML" | parse_attr "4shared\.com\/download\/" 'href')

    # Try to figure the real filename from HTML
    FILE_REAL_NAME=$(echo "$WAIT_HTML" | parse_quiet '<b class="blue xlargen">' \
                    'n">\([^<]\+\)' | html_to_utf8 | uri_decode)

    wait $((WAIT_TIME)) seconds || return 2

    echo "$FILE_URL"
    test "$FILE_REAL_NAME" && echo "$FILE_REAL_NAME"
    return 0
}

4shared_list() {
    eval "$(process_options sendspace "$MODULE_4SHARED_LIST_OPTIONS" "$@")"
    URL=$1

    if ! match '4shared\.com\/dir\/' "$URL"; then
        log_error "This is not a directory list"
        return 1
    fi

    PAGE=$(curl "$URL")
    match 'src="/images/spacer.gif" class="warn"' "$PAGE" &&
        { log_error "Link not found"; return 254; }
    echo "$PAGE" | parse_all_attr "alt=\"Download '" href ||
        { log_error "Cannot parse links"; return 1; }
}
