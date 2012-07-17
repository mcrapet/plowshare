#!/bin/bash
#
# uploadhero module
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

MODULE_UPLOADHERO_REGEXP_URL="http://\(www\.\)\?\(uploadhero\)\.com/"

MODULE_UPLOADHERO_DOWNLOAD_OPTIONS=""
MODULE_UPLOADHERO_DOWNLOAD_RESUME=no
MODULE_UPLOADHERO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_UPLOADHERO_LIST_OPTIONS=""

# Output an uploadhero file download URL
# $1: cookie file
# $2: uploadhero url
# stdout: real file download link
# Note: Anonymous download restriction: one file every 20 minutes
uploadhero_download() {
    local COOKIEFILE=$1
    local URL=$(echo "$2" | replace 'www.' '' | replace '/v/' '/dl/')
    local BASE_URL='http://uploadhero.com'
    local FILE_ID HTML PAGE FILE_NAME FILE_URL CAPTCHA_URL CAPTCHA_IMG
    local LIMIT_URL LIMIT_HTML LIMIT_MIN LIMIT_SEC WAIT_TIME

    # Recognize folders
    if match 'uploadhero.com/f/' "$URL"; then
        log_error "This is a directory list"
        return $ERR_FATAL
    fi

    # Get url content (in english)
    HTML=$(curl -c "$COOKIEFILE" -b "lang=en" "$URL") || return

    # Verify if link exists
    if match '<div class="raison">' "$HTML"; then
        return $ERR_LINK_DEAD
    fi

    # Check limit (one file every 20 minutes)
    if match 'id="lightbox_block_dl"' "$HTML"; then
        LIMIT_URL=$(echo "$HTML" | parse_attr 'id="lightbox_block_dl"' href)
        LIMIT_HTML=$(curl "$BASE_URL$LIMIT_URL") || return
        LIMIT_MIN=$(echo "$LIMIT_HTML" | parse_tag 'id="minutes"' span)
        LIMIT_SEC=$(echo "$LIMIT_HTML" | parse_tag 'id="seconds"' span)
        WAIT_TIME=$(($LIMIT_MIN * 60 + $LIMIT_SEC + 1))
        wait $WAIT_TIME seconds || return

        # Get a new page (hopefully without limit)
        HTML=$(curl -c "$COOKIEFILE" -b "lang=en" "$URL") || return
    fi

    # Extract the raw file id
    FILE_ID=$(echo "$URL" | parse 'uploadhero' '/dl/\([^/]*\)')
    log_debug "File id=$FILE_ID"

    # Extract filename (first <div> marker)
    FILE_NAME=$(echo "$HTML" | parse_tag 'class="nom_de_fichier"' div)
    log_debug "Filename : $FILE_NAME"

    # Handle captcha
    CAPTCHA_URL=$(echo "$HTML" | parse 'id="captcha"' 'src="\([^"]*\)')
    CAPTCHA_URL="$BASE_URL$CAPTCHA_URL"

    # Create new formatted image (cookie is mandatory)
    CAPTCHA_IMG=$(create_tempfile) || return
    curl -c "$COOKIEFILE" -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || return

    # Decode captcha
    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG") || return
    { read WORD; read ID; } <<<"$WI"
    rm -f "$CAPTCHA_IMG"

    log_debug "decoded captcha: $WORD"

    # Get final url
    PAGE=$(curl -b "$COOKIEFILE" -c "$COOKIEFILE" "$URL?code=$WORD") || return

    if ! match 'setTimeout' "$PAGE"; then
        captcha_nack $ID
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    elif match 'magicomfg' "$PAGE"; then
        FILE_URL=$(echo "$PAGE" | parse_attr 'magicomfg' href) || return
    else
        log_error "No match. Site update?"
        return $ERR_FATAL
    fi

    captcha_ack $ID
    log_debug "correct captcha"

    # Wait 46 seconds (we should parse the javascript function setTimeout to extract 46000, but it is multiline...)
    wait 46 seconds || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# List an uploadhero shared file folder URL
# $1: uploadhero url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
uploadhero_list() {
    local URL=$1
    local PAGE NAMES LINKS

    # check whether it looks like a folder link
    if ! match "${MODULE_UPLOADHERO_REGEXP_URL}f/" "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    test "$2" && log_error "Recursive flag not implemented, ignoring"

    PAGE=$(curl -L "$URL") || return

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet '<td class="td4">' href)
    NAMES=$(echo "$PAGE" | parse_all_tag_quiet '<td class="td2">' td | html_to_utf8)

    list_submit "$LINKS" "$NAMES" || return
}
