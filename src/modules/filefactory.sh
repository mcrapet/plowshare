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

MODULE_FILEFACTORY_REGEXP_URL="http://\(www\.\)\?filefactory\.com/file"
MODULE_FILEFACTORY_DOWNLOAD_OPTIONS=""
MODULE_FILEFACTORY_UPLOAD_OPTIONS=
MODULE_FILEFACTORY_DOWNLOAD_CONTINUE=yes

# Output a filefactory file download URL (anonymous, NOT PREMIUM)
#
# filefactory_download FILEFACTORY_URL
#
filefactory_download() {
    set -e
    eval "$(process_options filefactory "$MODULE_FILEFACTORY_DOWNLOAD_OPTIONS" "$@")"

    BASE_URL="http://www.filefactory.com"

    detect_javascript >/dev/null || return 1

    # Round 1
    HTML_PAGE=$(curl "$1")

    match 'button\.basic\.jpg\|Download Now' "$HTML_PAGE" ||
        { log_debug "file not found"; return 254; }

    test "$CHECK_LINK" && return 255

    WAIT_URL=$(get_next_link "$HTML_PAGE" 'class="basicBtn"' '<\/script>') ||
        { log_error "can't get wait url, website updated?"; return 1; }

    # Round 2
    HTML_PAGE=$(curl "${BASE_URL}${WAIT_URL}")
    FILE_URL=$(get_next_link "$HTML_PAGE" 'id="downloadLink"' '<\/script>') ||
        { log_error "can't get file url, website updated?"; return 1; }

    WAIT_TIME=$(echo "$HTML_PAGE" | parse '<span class="countdown">' '>\([[:digit:]]*\)<\/span>')
    wait $((WAIT_TIME)) seconds

    echo $FILE_URL
}

# Local funtion. Extract the right <script>..</script> snippet
# and then use it to get a link.
#
# $1: HTML content
# $2: upper bound
# $2: lower bound
get_next_link() {
    local CHUNK=$(echo "$1" | sed -n "/$2/,/$3/p")

    if match 'href="javascript:void(0);"' "$CHUNK"; then
        KEY=$(echo "$CHUNK" | parse 'var ' '?key="[^"]*"\([^"]*\)')
        log_debug "key:$KEY"

        JSCODE=$(curl "${BASE_URL}/file/getLink.js?key=$KEY" | sed -n '$!p')

        # Allow a second attempt
        if match 'Unknown Request' "$JSCODE"; then
            log_debug "second attempt for getLink"
            JSCODE=$(curl "${BASE_URL}/file/getLink.js?key=$KEY" | sed -n '$!p')
        fi

        VAR=$(echo "$JSCODE" | parse 'var' 'var \([^ ]*\)')
        log_debug "js var name: $VAR"

        LINK=$(echo "$JSCODE" " print($VAR);" | javascript) ||
            { log_error "can't exectute javascript, website updated?"; return 1; }
    else
        LINK=$(echo "$CHUNK" | parse_attr '<a href=' 'href') ||
            { log_error "can't exectute javascript, website updated?"; return 1; }
    fi

    log_debug "link:$LINK"
    echo "$LINK"
}
