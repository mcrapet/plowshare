#!/bin/bash
#
# divshare.com module
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

MODULE_DIVSHARE_REGEXP_URL="http://\(www\.\)\?divshare\.com/download"

MODULE_DIVSHARE_DOWNLOAD_OPTIONS=""
MODULE_DIVSHARE_DOWNLOAD_RESUME=no
MODULE_DIVSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

# Output a divshare file download URL
# $1: cookie file
# $2: divshare url
# stdout: real file download link
divshare_download() {
    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://www.divshare.com'
    local PAGE REDIR_URL WAIT_PAGE WAIT_TIME FILE_URL FILENAME

    PAGE=$(curl -c "$COOKIEFILE" "$URL") || return

    if match '<div id="fileInfoHeader">File Information</div>'; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Uploader can disable audio/video download (only streaming is available)
    REDIR_URL=$(echo "$PAGE" | parse_attr_quiet 'btn_download_new' 'href') || {
        log_error "content download not allowed";
        return $ERR_LINK_DEAD;
    }

    if ! match_remote_url "$REDIR_URL"; then
        WAIT_PAGE=$(curl -b "$COOKIEFILE" "${BASE_URL}$REDIR_URL")
        WAIT_TIME=$(echo "$WAIT_PAGE" | parse_quiet 'http-equiv="refresh"' 'content="\([^;]*\)')
        REDIR_URL=$(echo "$WAIT_PAGE" | parse 'http-equiv="refresh"' 'url=\([^"]*\)')

        # Usual wait time is 15 seconds
        wait $((WAIT_TIME)) seconds || return

        PAGE=$(curl -b "$COOKIEFILE" "${BASE_URL}$REDIR_URL") || return
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr 'btn_download_new' 'href') || return
    FILENAME=$(echo "$PAGE" | parse_tag title)

    echo $FILE_URL
    echo "${FILENAME% - DivShare}"
}
