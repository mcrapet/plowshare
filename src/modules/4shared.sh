#!/bin/bash
#
# 4shared.com module
# Copyright (c) 2010-2012 Plowshare team
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

MODULE_4SHARED_REGEXP_URL="https\?://\(www\.\)\?4shared\.com/"

MODULE_4SHARED_DOWNLOAD_OPTIONS=""
MODULE_4SHARED_DOWNLOAD_RESUME=no
MODULE_4SHARED_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_4SHARED_LIST_OPTIONS="
DIRECT_LINKS,,direct,,Show direct links (if available) instead of regular ones"

# Output a 4shared file download URL
# $1: cookie file
# $2: 4shared url
# stdout: real file download link
4shared_download() {
    local COOKIEFILE="$1"
    local URL="$2"
    local REAL_URL URL PAGE WAIT_URL FILE_URL FILE_NAME

    REAL_URL=$(curl -I "$URL" | grep_http_header_location) || return
    if test "$REAL_URL"; then
        URL=$REAL_URL
    fi

    PAGE=$(curl -c "$COOKIEFILE" -b '4langcookie=en' "$URL") || return
    if match '4shared\.com/dir/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return $ERR_FATAL
    elif match 'The file link that you requested is not valid.' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    WAIT_URL=$(echo "$PAGE" | parse_attr '4shared\.com\/get\/' 'href') || return

    test "$CHECK_LINK" && return 0

    WAIT_HTML=$(curl -b "$COOKIEFILE" "$WAIT_URL") || return

    WAIT_TIME=$(echo "$WAIT_HTML" | parse 'var c =' \
            '[[:space:]]\([[:digit:]]\+\);')
    FILE_URL=$(echo "$WAIT_HTML" | parse_attr '4shared\.com\/download\/' 'href')

    # Try to figure the real filename from HTML
    FILE_NAME=$(echo "$WAIT_HTML" | parse_quiet '<b class="blue xlargen">' \
            'n">\([^<]\+\)' | html_to_utf8 | uri_decode)

    wait $((WAIT_TIME)) seconds || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# List a 4shared folder URL
# $1: 4shared.com link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
4shared_list() {
    eval "$(process_options 4shared "$MODULE_4SHARED_LIST_OPTIONS" "$@")"

    local URL=$(echo "$1" | replace '/folder/' '/dir/')
    local PAGE

    # There are two views:
    # - Simple view link (URL with /folder/)
    # - Advanced view link (URL with /dir/)
    if ! match '4shared\.com/dir/' "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    test "$2" && log_debug "recursive flag is not supported"

    PAGE=$(curl "$URL") || return

    match 'src="/images/spacer.gif" class="warn"' "$PAGE" &&
        { log_error "Site updated?"; return $ERR_FATAL; }

    if test "$DIRECT_LINKS"; then
        log_debug "Note: provided links are temporary! Use 'curl -J -O' on it."
        echo "$PAGE" | parse_all_attr_quiet \
            'class="icon16 download"' href || return $ERR_LINK_DEAD
    else
        echo "$PAGE" | parse_all "openNewWindow('" \
            "('\([^']*\)" || return $ERR_LINK_DEAD
    fi
}
