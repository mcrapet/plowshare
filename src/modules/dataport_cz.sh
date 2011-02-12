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
MODULE_DATAPORT_CZ_UPLOAD_OPTIONS=""
MODULE_DATAPORT_CZ_DOWNLOAD_CONTINUE=yes

# Output a dataport.cz file download URL
# $1: DATAPORT_CZ_URL
# stdout: real file download link
dataport_cz_download() {
    set -e
    eval "$(process_options dataport_cz "$MODULE_DATAPORT_CZ_DOWNLOAD_OPTIONS" "$@")"

    URL=$(uri_encode_file "$1")

    # html returned uses utf-8 charset
    PAGE=$(curl --location "$URL")
    if ! match "<h2>Stáhnout soubor</h2>" "$PAGE"; then
        log_error "File not found."
        return 254
    elif ! match "Volné sloty pro stažení zdarma jsou v tuto chvíli k dispozici.</span>" "$PAGE"; then
        log_error "Free slots are exhausted at the moment, please try again later."
        return 255
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

dataport_cz_upload() {
    set -e
    eval "$(process_options dataport_cz "$MODULE_DATAPORT_CZ_UPLOAD_OPTIONS" "$@")"

    local FILE=$1
    local DESTFILE=${2:-$FILE}
    local UPLOADURL="http://dataport.cz/"

    COOKIES=$(create_tempfile)

    PAGE=$(curl -c "$COOKIES" --location "$UPLOADURL")

    REFERRER=$(echo "$PAGE" | parse_quiet '<iframe src="' '<iframe src="*\([^<]*\)')

    ID=$(echo "var uid = Math.floor(Math.random()*999999999); print(uid);" | javascript)

    STATUS=$(curl_with_log -b "$COOKIES" -e "$REFERRER" \
        -F "id=0" \
        -F "folder=/upload/uploads" \
        -F "uid=$ID" \
        -F "Upload=Submit Query" \
        -F "Filedata=@$FILE;filename=$(basename_file "$DESTFILE")" \
        "http://www10.dataport.cz/save.php")

    if ! test "$STATUS"; then
        log_error "Uploading error."
        rm -f "$COOKIES"
        return 1
    fi

    DOWN_URL=$(curl -b "$COOKIES" "http://dataport.cz/links/$ID/1" | parse_attr 'id="download-link"' 'value')

    rm -f "$COOKIES"

    if ! test "$DOWN_URL"; then
        log_error "Can't parse download link, site updated?"
        return 1
    fi

    echo "$DOWN_URL"
    return 0
}

# urlencode only the file part by splitting with last slash
uri_encode_file() {
    echo "${1%/*}/$(echo "${1##*/}" | uri_encode_strict)"
}
