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
#
# Author: halfman <Pulpan3@gmail.com>

MODULE_DATAPORT_CZ_REGEXP_URL="http://\(www\.\)\?dataport\.cz/"
MODULE_DATAPORT_CZ_DOWNLOAD_OPTIONS=""
MODULE_DATAPORT_CZ_DOWNLOAD_CONTINUE=yes

# Output a dataport.cz file download URL
# $1: DATAPORT_CZ_URL
# stdout: real file download link
dataport_cz_download() {
    set -e
    eval "$(process_options dataport_cz "$MODULE_DATAPORT_CZ_DOWNLOAD_OPTIONS" "$@")"

    URL=$(uri_encode_file "$1")

    PAGE=$(curl --location "$URL")
    if ! match "<h2>Stáhnout soubor</h2>" "$PAGE"; then
        log_error "File not found."
        return 254
    fi

    DL_URL=$(echo "$PAGE" | parse_quiet '<td>' '<td><a href="\([^"]*\)')
    if ! test "$DL_URL"; then
        log_error "Can't parse download URL, site updated?"
        return 255
    fi
    DL_URL=$(uri_encode_file "$DL_URL")

    FILENAME=$(echo "$PAGE" | parse_quiet '<td><strong>' '<td><strong>*\([^<]*\)')

    FILE_URL=$(curl -I "$DL_URL" | grep_http_header_location)
    if ! test "$FILE_URL"; then
        log_error "Location not found"
        return 255
    fi
    FILE_URL=$(uri_encode_file "$FILE_URL")

    test "$CHECK_LINK" && return 255

    echo "$FILE_URL"
    test "$FILENAME" && echo "$FILENAME"

    return 0
}

# urlencode only the file part by splitting with last slash
uri_encode_file() {
    echo "${1%/*}/$(echo "${1##*/}" | uri_encode_strict)"
}
