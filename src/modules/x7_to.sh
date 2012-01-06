#!/bin/bash
#
# x7.to module
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

MODULE_X7_TO_REGEXP_URL="http://\(www\.\)\?x7\.to/"

MODULE_X7_TO_DOWNLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Use Free account"
MODULE_X7_TO_DOWNLOAD_RESUME=no
MODULE_X7_TO_FINAL_LINK_NEEDS_COOKIE=no

# Output a x7.to file download URL
# $1: cookie file
# $2: x7.to url
# stdout: real file download link
x7_to_download() {
    eval "$(process_options x7_to "$MODULE_X7_TO_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL="$2"
    local BASE_URL='http://x7.to'

    if [ -z "$AUTH_FREE" ]; then
        curl -c "$COOKIEFILE" -o /dev/null "$URL"
    else
        # Do the secure HTTP login! Adding --referer is mandatory.
        LOGIN_DATA='id=$USER&pw=$PASSWORD'
        LOGIN_RESULT=$(post_login "$AUTH_FREE" "$COOKIEFILE" "$LOGIN_DATA" \
                "${BASE_URL}/james/login" "--referer ${BASE_URL}") || return

        # {err:"Benutzer und Passwort stimmen nicht überein."}
        if match '^{err:' "$LOGIN_RESULT"; then
            log_error "login process failed"
            return $ERR_FATAL
        fi
    fi

    local WAIT_HTML REF_FID FILE_REAL_NAME EXTENSION DATA
    local J_TYPE J_WAIT J_LINK

    WAIT_HTML=$(curl -L -b $COOKIEFILE "$URL") || return
    REF_FID=$(echo "$WAIT_HTML" | parse_quiet 'document.cookie[[:space:]]=[[:space:]]*' \
            'ref_file=\([^&]*\)')

    if [ -z "$REF_FID" ]; then
        matchi 'file not found' "$WAIT_HTML" &&
            log_debug "File not found"

        if match '<span id="foldertitle">' "$WAIT_HTML"; then
            local textlist=$(echo "$WAIT_HTML" | parse_attr 'listplain' 'href')
            log_error "This is a folder list (check $BASE_URL/$textlist)"
        fi

        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Check for errors:
    # - The requested file is larger than 400MB, only premium members will be able to download the file!
    if match 'requested file is larger than' "$WAIT_HTML"; then
        log_debug "premium link"
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FILE_REAL_NAME=$(echo "$WAIT_HTML" | parse_quiet '<span style="text-shadow:#5855aa 1px 1px 2px">' \
            '>\([^<]*\)<small')
    EXTENSION=$(echo "$WAIT_HTML" | parse_quiet '<span style="text-shadow:#5855aa 1px 1px 2px">' \
            '<small[^>]*>\([^<]*\)<\/small>')
    FILE_REAL_NAME="$FILE_REAL_NAME$EXTENSION"

    # According to http://x7.to/js/download.js
    DATA=$(curl -b $COOKIEFILE \
            -b "cookie_test=enabled; ref=ref_user=6649&ref_file=${REF_FID}&url=&date=1234567890" \
            --data-binary "" \
            --referer "$URL" \
            "$BASE_URL/james/ticket/dl/$REF_FID") || return

    # Parse JSON object
    # {type:'download',wait:12,url:'http://stor2.x7.to/dl/Z5H3o51QqB'}
    # {err:"Download denied."}
    J_TYPE=$(echo "$DATA" | parse_quiet '^' "type[[:space:]]*:[[:space:]]*'\([^']*\)")
    J_WAIT=$(echo "$DATA" | parse_quiet '^' 'wait[[:space:]]*:[[:space:]]*\([[:digit:]]*\)')
    J_LINK=$(echo "$DATA" | parse_quiet '^' "url[[:space:]]*:[[:space:]]*'\([^']*\)")

    if [ "$J_TYPE" == "download" ]; then
        wait $((J_WAIT)) seconds || return
    elif match 'limit-dl\|limit-parallel' "$DATA"; then
        log_debug "Download limit reached!"
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    else
        local ERROR=$(echo "$DATA" | parse_quiet 'err:' '{err:"\([^"]*\)"}')
        log_error "failed state [$ERROR]"
        return $ERR_FATAL
    fi

    # Example of URL:
    # http://stor4.x7.to/dl/IMDju9Fk5y
    # Real filename is also stored in "Content-Disposition" HTTP header

    echo "$J_LINK"
    test -n "$FILE_REAL_NAME" && echo "$FILE_REAL_NAME"
    return 0
}
