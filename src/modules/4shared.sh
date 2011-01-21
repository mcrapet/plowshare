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

MODULE_4SHARED_REGEXP_URL="http://\(www\.\)\?4shared\.com/"
MODULE_4SHARED_DOWNLOAD_OPTIONS=""
MODULE_4SHARED_UPLOAD_OPTIONS=
MODULE_4SHARED_LIST_OPTIONS=
MODULE_4SHARED_DOWNLOAD_CONTINUE=no

# Output a 4shared file download URL
#
# $1: A 4shared URL
#
4shared_download() {
    set -e
    eval "$(process_options 4shared "$MODULE_4SHARED_DOWNLOAD_OPTIONS" "$@")"
    URL=$1

    if match '4shared\.com\/dir\/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return 1
    fi

    COOKIES=$(create_tempfile)
    WAIT_URL=$(curl -c $COOKIES "$URL" | parse_attr "4shared\.com\/get\/" 'href') || {
        rm -f $COOKIES
        log_debug "file not found"
        return 254
    }

    test "$CHECK_LINK" && return 255

    WAIT_HTML=$(curl -b $COOKIES "$WAIT_URL")
    rm -f $COOKIES

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
