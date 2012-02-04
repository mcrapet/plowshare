#!/bin/bash
#
# dataport.cz module
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

MODULE_DATAPORT_CZ_REGEXP_URL="http://\(www\.\)\?dataport\.cz/"

MODULE_DATAPORT_CZ_DOWNLOAD_OPTIONS=""
MODULE_DATAPORT_CZ_DOWNLOAD_RESUME=yes
MODULE_DATAPORT_CZ_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

MODULE_DATAPORT_CZ_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_DATAPORT_CZ_UPLOAD_REMOTE_SUPPORT=no

MODULE_DATAPORT_CZ_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account (mandatory)"

# Output a dataport.cz file download URL
# $1: cookie file (unused here)
# $2: dataport.cz url
# stdout: real file download link
dataport_cz_download() {
    eval "$(process_options dataport_cz "$MODULE_DATAPORT_CZ_DOWNLOAD_OPTIONS" "$@")"

    local URL=$(uri_encode_file "$2")
    local PAGE DL_URL FILENAME FILE_URL

    PAGE=$(curl --location "$URL") || return
    if match '<h2>Soubor nebyl nalezen</h2>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Returned HTML uses UTF-8 charset
    # <strong><span style="color:green">Volné sloty pro stažení zdarma jsou v tuto chvíli k dispozici.</span></strong>
    # <strong><span style="color:red">Volné sloty pro stažení zdarma jsou v tuhle chvíli vyčerpány.</span></strong>
    PAGE=$(curl --location "$URL") || return

    if ! match 'color:green">Volné sloty pro' "$PAGE"; then
        echo 120
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FILENAME=$(echo "$PAGE" | parse_tag 'color: red' 'h2')

    # Can't use parse_attr because there are 2 href on the same line
    DL_URL=$(echo "$PAGE" | sed -e 's/<strong/\n<strong/g' | \
        parse_attr 'ui-state-default' href) || return

    # Is this required ?
    DL_URL=$(uri_encode_file "$DL_URL")

    FILE_URL=$(curl -I "$DL_URL" | grep_http_header_location) || return

    # Is this required ?
    FILE_URL=$(uri_encode_file "$FILE_URL")

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to dataport.cz
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
dataport_cz_upload() {
    eval "$(process_options dataport_cz "$MODULE_DATAPORT_CZ_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local FILE="$2"
    local DESTFILE="$3"
    local UPLOADURL='http://dataport.cz'

    detect_javascript || return

    if test "$AUTH"; then
        LOGIN_DATA='name=$USER&x=0&y=0&pass=$PASSWORD'
        post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" "$UPLOADURL/prihlas/" >/dev/null || return

        PAGE=$(curl -b "$COOKIEFILE" --location "$UPLOADURL") || return

        if ! match "http://dataport.cz/odhlasit/" "$PAGE"; then
            return $ERR_LOGIN_FAILED
        fi
    fi

    PAGE=$(curl -b "$COOKIEFILE" --location "$UPLOADURL") || return

    REFERRER=$(echo "$PAGE" | parse_attr '<iframe' 'src')
    UZIV_ID=$(echo "$REFERRER" | parse_quiet 'uziv_id' 'uziv_id=\(.*\)')
    ID=$(echo "var uid = Math.floor(Math.random()*999999999); print(uid);" | javascript)

    STATUS=$(curl_with_log -b "$COOKIEFILE" -e "$REFERRER" \
        -F "id=$UZIV_ID" \
        -F "folder=/upload/uploads" \
        -F "uid=$ID" \
        -F "Upload=Submit Query" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        "http://www10.dataport.cz/save.php")

    if ! test "$STATUS"; then
        log_error "Uploading error."
        return $ERR_FATAL
    fi

    DOWN_URL=$(curl -b "$COOKIEFILE" "$UPLOADURL/links/$ID/1" | parse_attr 'id="download-link"' 'value')

    if ! test "$DOWN_URL"; then
        log_error "Can't parse download link, site updated?"
        return $ERR_FATAL
    fi

    echo "$DOWN_URL"
    return 0
}

# Delete a file on dataport.cz (requires an account)
# $1: download link
dataport_cz_delete() {
    eval "$(process_options dataport_cz "$MODULE_DATAPORT_CZ_DELETE_OPTIONS" "$@")"

    local URL="$1"
    local BASE_URL=$(basename_url $URL)

    if ! test "$AUTH"; then
        log_error "Anonymous users cannot delete links."
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    COOKIES=$(create_tempfile) || return
    LOGIN_DATA='name=$USER&x=0&y=0&pass=$PASSWORD'
    post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" "$BASE_URL/prihlas/" >/dev/null || {
        rm -f $COOKIES
        return $ERR_FATAL
    }

    DEL_URL=$(echo "$URL" | replace 'file' 'delete')

    DELETE=$(curl -I -b $COOKIES $DEL_URL | grep_http_header_location)

    rm -f $COOKIES

    if ! match "vymazano" "$DELETE"; then
        log_error "Error deleting link."
        return $ERR_FATAL
    fi
}

# urlencode only the file part by splitting with last slash
uri_encode_file() {
    echo "${1%/*}/$(echo "${1##*/}" | uri_encode_strict)"
}
