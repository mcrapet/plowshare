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

MODULE_DIVSHARE_REGEXP_URL="http://\(www\.\)\?divshare\.com/download"
MODULE_DIVSHARE_DOWNLOAD_OPTIONS=""
MODULE_DIVSHARE_DOWNLOAD_CONTINUE=no

# Output a divshare file download URL
#
# $1: A divshare URL
#
divshare_download() {
    set -e
    eval "$(process_options divshare "$MODULE_DIVSHARE_DOWNLOAD_OPTIONS" "$@")"

    BASE_URL='http://www.divshare.com'
    COOKIES=$(create_tempfile)

    PAGE=$(curl -c "$COOKIES" "$1")

    if match '<div id="fileInfoHeader">File Information</div>'; then
        log_debug "file not found"
        rm -f $COOKIES
        return 254
    fi

    if test "$CHECK_LINK"; then
        rm -f $COOKIES
        return 255
    fi

    # Uploader can disable audio/video download (only streaming is available)
    REDIR_URL=$(echo "$PAGE" | parse_attr 'btn_download_new' 'href' 2>/dev/null) || {
        log_error "content download not allowed"
        rm -f $COOKIES
        return 254
    }

    if ! match '^http' "$REDIR_URL"; then
        WAIT_PAGE=$(curl -b "$COOKIES" "${BASE_URL}$REDIR_URL")
        WAIT_TIME=$(echo "$WAIT_PAGE" | parse 'http-equiv="refresh"' 'content="\([^;]*\)' 2>/dev/null)
        REDIR_URL=$(echo "$WAIT_PAGE" | parse 'http-equiv="refresh"' 'url=\([^"]*\)')

        # Usual wait time is 15 seconds
        wait $((WAIT_TIME)) seconds || return 2

        PAGE=$(curl -b "$COOKIES" "${BASE_URL}$REDIR_URL")
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr 'btn_download_new' 'href') ||
        { log_debug "can't get link, website updated?"; }
    FILENAME=$(echo "$PAGE" | parse '<title>' '<title>\([^<]*\)') ||
        { log_debug "can't parse filename, website updated?"; }

    echo $FILE_URL
    echo "${FILENAME% - DivShare}"
    echo $COOKIES
}
