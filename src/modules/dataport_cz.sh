#!/bin/bash
#
# dataport.cz module
# Copyright (c) 2011 halfman <Pulpan3@gmail.com>
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
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or VIP account"
MODULE_DATAPORT_CZ_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Login to free or VIP account (required)"

# Output a dataport.cz file download URL
# $1: cookie file (unused here)
# $2: dataport.cz url
# stdout: real file download link
dataport_cz_download() {
    local URL=$(uri_encode_file "$2")
    local PAGE=$(curl --location "$URL")

    if ! match "<h2>Stáhnout soubor</h2>" "$PAGE"; then
        log_error "File not found."
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Arbitrary wait (local variable)
    NO_FREE_SLOT_IDLE=125

    while retry_limit_not_reached || return; do

        # html returned uses utf-8 charset
        PAGE=$(curl --location "$URL")
        if ! match "Volné sloty pro stažení zdarma jsou v tuto chvíli k dispozici.</span>" "$PAGE"; then
            no_arbitrary_wait || return
            wait $NO_FREE_SLOT_IDLE seconds || return
            continue
        fi
        break
    done

    DL_URL=$(echo "$PAGE" | parse_quiet '<td>' '<td><a href="\([^"]*\)')
    if ! test "$DL_URL"; then
        log_error "Can't parse download URL, site updated?"
        return 1
    fi
    DL_URL=$(uri_encode_file "$DL_URL")

    FILENAME=$(echo "$PAGE" | parse_quiet '<td><strong>' '<td><strong>*\([^<]*\)')

    FILE_URL=$(curl -I "$DL_URL" | grep_http_header_location)
    if ! test "$FILE_URL"; then
        log_error "Location not found"
        return 1
    fi
    FILE_URL=$(uri_encode_file "$FILE_URL")

    echo "$FILE_URL"
    test "$FILENAME" && echo "$FILENAME"

    return 0
}

dataport_cz_upload() {
    eval "$(process_options dataport_cz "$MODULE_DATAPORT_CZ_UPLOAD_OPTIONS" "$@")"

    local FILE=$1
    local DESTFILE=${2:-$FILE}
    local UPLOADURL="http://dataport.cz/"

    COOKIES=$(create_tempfile)
    if test "$AUTH"; then
        LOGIN_DATA='name=$USER&x=0&y=0&pass=$PASSWORD'
        post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" "$UPLOADURL/prihlas/" >/dev/null || {
            rm -f $COOKIES
            return 1
        }

        PAGE=$(curl -b "$COOKIES" --location "$UPLOADURL")

        if ! match "http://dataport.cz/odhlasit/" "$PAGE"; then
            rm -f $COOKIES
            return $ERR_LOGIN_FAILED
        fi
    fi

    PAGE=$(curl -b "$COOKIES" --location "$UPLOADURL")

    REFERRER=$(echo "$PAGE" | parse_attr '<iframe' 'src')

    UZIV_ID=$(echo "$REFERRER" | parse_quiet 'uziv_id' 'uziv_id=\(.*\)')

    ID=$(echo "var uid = Math.floor(Math.random()*999999999); print(uid);" | javascript)

    STATUS=$(curl_with_log -b "$COOKIES" -e "$REFERRER" \
        -F "id=$UZIV_ID" \
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

    COOKIES=$(create_tempfile)
    LOGIN_DATA='name=$USER&x=0&y=0&pass=$PASSWORD'
    post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" "$BASE_URL/prihlas/" >/dev/null || {
        rm -f $COOKIES
        return 1
    }

    DEL_URL=$(echo "$URL" | replace 'file' 'delete')

    DELETE=$(curl -I -b $COOKIES $DEL_URL | grep_http_header_location)

    rm -f $COOKIES

    if ! match "vymazano" "$DELETE"; then
        log_error "Error deleting link."
        return 1
    fi
}

# urlencode only the file part by splitting with last slash
uri_encode_file() {
    echo "${1%/*}/$(echo "${1##*/}" | uri_encode_strict)"
}
