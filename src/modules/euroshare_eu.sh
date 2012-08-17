#!/bin/bash
#
# euroshare.eu module
# Copyright (c) 2011 halfman <Pulpan3@gmail.com>
# Copyright (c) 2012 Plowshare team
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

MODULE_EUROSHARE_EU_REGEXP_URL="http://\(www\.\)\?euroshare\.eu/"

MODULE_EUROSHARE_EU_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_EUROSHARE_EU_DOWNLOAD_RESUME=no
MODULE_EUROSHARE_EU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_EUROSHARE_EU_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
DESCRIPTION,d,description,S=DESCRIPTION,Set file description"
MODULE_EUROSHARE_EU_UPLOAD_REMOTE_SUPPORT=no

MODULE_EUROSHARE_EU_DELETE_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account (mandatory)"

# Static function. Proceed with login (free)
# $1: authentication
# $2: cookie file
# $3: base url
euroshare_eu_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE EMAIL

    LOGIN_DATA='login=$USER&password=$PASSWORD+&trvale=1'
    PAGE=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/customer-zone/login/" -L) || return

    # <p>Boli ste úspešne prihlásený</p>
    match 'Boli ste úspešne prihlásený' "$PAGE" || return $ERR_LOGIN_FAILED

    # <li><a href="/customer-zone/logout/" title="Odhlásiť">Odhlásiť (xyz)</a></li>
    EMAIL=$(echo "$PAGE" | parse 'Odhlásiť' 'Odhlásiť (\([^)]\+\))') || return

    log_debug "Successfully logged in as member '$EMAIL'"
}

# Output a Euroshare.eu file download URL
# $1: cookie file
# $2: euroshare.eu url
# stdout: real file download link
#         file name
euroshare_eu_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.euroshare.eu'
    local PAGE DL_URL

    # HTML returned uses UTF-8 charset
    PAGE=$(curl "$URL") || return

    # <strong>Požadovaný súbor sa na serveri nenachádza alebo bol odstránený</strong>
    match 'Požadovaný súbor sa na serveri nenachádza' "$PAGE" && return $ERR_LINK_DEAD
    [ -n "$CHECK_LINK" ] && return 0

    if [ -n "$AUTH_FREE" ]; then
        euroshare_eu_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

    # <a href="/file/15529848/xyz/download/"><div class="downloadButton" >Stiahnuť</div></a>
    DL_URL="$BASE_URL"$(echo "$PAGE" | \
        parse 'Stiahnuť' 'href="\(/file/.\+/download/\)">') || return
    DL_URL=$(curl -i "$DL_URL") || return

    # Extract + output download link and file name
    echo "$DL_URL" | grep_http_header_location || return
    echo "$PAGE" | parse_tag 'strong' || return
}

# Upload a file to Euroshare.eu
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
#         delete link
euroshare_eu_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.euroshare.eu'
    local JSON

    if [ -n "$AUTH_FREE" ]; then
        euroshare_eu_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    JSON=$(curl_with_log -b "$COOKIE_FILE" -H 'X-Requested-With: XMLHttpRequest' \
        -F "description=$DESCRIPTION" \
        -F 'category=0' \
        -F "files[]=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        "$BASE_URL/ajax/upload/file/") || return

    # Extract + output download link and delete link
    echo "$JSON" | parse_json url || return
    echo "$JSON" | parse_json delete_url || return
}

# Delete a file from Euroshare.eu
# $1: cookie file (unused here)
# $2: euroshare.eu (delete) link
euroshare_eu_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.euroshare.eu'
    local PAGE FILE_ID

    PAGE=$(curl "$URL") || return

    # <p>Požadovaný súbor neexistuje alebo už bol odstránený!<p>
    match 'Požadovaný súbor neexistuje' "$PAGE" && return $ERR_LINK_DEAD

    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS

    # Note: Deletion page does not work, so we use the file manager instead
    FILE_ID=$(echo "$URL" | \
        parse_quiet . '/delete/[[:alnum:]]\+/\([[:digit:]]\+\)/')

    if [ -z "$FILE_ID" ]; then
        log_error 'This is not a delete link.'
        return $ERR_FATAL
    fi
    log_debug "File ID: '$FILE_ID'"

    euroshare_eu_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    PAGE=$(curl -b "$COOKIE_FILE" -H 'X-Requested-With: XMLHttpRequest' \
        -d "id=item_$FILE_ID" \
        "$BASE_URL/ajax/file-manager/file-remove/") || return

    if ! match 'Array' "$PAGE"; then
        log_error 'Could not delete file. Site updated?'
        return $ERR_FATAL
    fi
}
