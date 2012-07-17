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
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_DATAPORT_CZ_UPLOAD_REMOTE_SUPPORT=no

MODULE_DATAPORT_CZ_DELETE_OPTIONS=""

# Static function. Proceed with login (free or premium)
dataport_cz_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT

    LOGIN_DATA='username=$USER&password=$PASSWORD&loginFormSubmit='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/?do=loginForm-submit" -L) || return

    # <a href="/user/register">Registrace</a>&nbsp;
    if match '/user/register' "$LOGIN_RESULT"; then
        return $ERR_LOGIN_FAILED
    fi

    # If successful, cookie entry PHPSESSID is updated
}

# Output a dataport.cz file download URL
# $1: cookie file (unused here)
# $2: dataport.cz url
# stdout: real file download link
dataport_cz_download() {
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
    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://dataport.cz'
    local IURL PAGE FORM_ACTION FORM_SUBMIT DL_LINK DEL_LINK

    if test "$AUTH"; then
        dataport_cz_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$BASE_URL") || return

    IURL=$(echo "$PAGE" | parse_attr '<iframe' 'src') || return
    PAGE=$(curl -L -b "$COOKIE_FILE" "$IURL") || return

    FORM_ACTION=$(echo "$PAGE" | parse_form_action | replace '&amp;' '&') || return
    FORM_SUBMIT=$(echo "$PAGE" | parse_form_input_by_name 'uploadFormSubmit') || return

    PAGE=$(curl_with_log -L -b "$COOKIE_FILE" -e "$IURL" \
        -F "file=@$FILE;filename=$DESTFILE" \
        -F "uploadFormSubmit=$FORM_SUBMIT" \
        -F "description=None" \
        "$(basename_url "$IURL")$FORM_ACTION") || return

    DL_LINK=$(echo "$PAGE" | parse_attr '/file/' value) || return
    DEL_LINK=$(echo "$PAGE" | parse_attr delete value)

    echo "$DL_LINK"
    echo "$DEL_LINK"
}

# Delete a file on dataport.cz
# $1: cookie file (unused here)
# $2: download link
dataport_cz_delete() {
    local URL=$2
    local PAGE

    PAGE=$(curl -L -I "$URL" | grep_http_header_location) || return

    if [ "$PAGE" = 'http://dataport.cz/' ]; then
        return $ERR_FATAL
    fi
}

# urlencode only the file part by splitting with last slash
uri_encode_file() {
    echo "${1%/*}/$(echo "${1##*/}" | uri_encode_strict)"
}
