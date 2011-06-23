#!/bin/bash
#
# wupload.com module
# Copyright (c) 2011 Plowshare team
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

MODULE_WUPLOAD_REGEXP_URL="http://\(www\.\)\?wupload\.com/"

MODULE_WUPLOAD_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or premium account"
MODULE_WUPLOAD_LIST_OPTIONS=""


# Upload a file to wupload using wupload api - http://api.wupload.com/user
# $1: file name to upload
# $2: upload as file name (optional, defaults to $1)
# stdout: download link on wupload
wupload_upload() {
    eval "$(process_options wupload "$MODULE_WUPLOAD_UPLOAD_OPTIONS" "$@")"

    local FILE=$1
    local DESTFILE=${2:-$FILE}
    local BASE_URL="http://api.wupload.com/"

    if ! test "$AUTH"; then
        log_error "anonymous users cannot upload files"
        return 1
    fi

    USER="${AUTH%%:*}"
    PASSWORD="${AUTH#*:}"

    if [ "$AUTH" = "$PASSWORD" ]; then
        PASSWORD=$(prompt_for_password) || \
        { log_error "You must provide a password"; return 4; }
    fi

    # Not secure !
    JSON=$(curl "$BASE_URL/upload?method=getUploadUrl&u=$USER&p=$PASSWORD") || return 1

    # Login failed. Please check username or password.
    if match "Login failed" "$JSON"; then
        log_debug "login failed"
        return 1
    fi

    log_debug "Successfully logged in as $USER member"

    URL=$(echo "$JSON" | parse 'url' ':"\([^"]*json\)"')
    URL=${URL//[\\]/}

    # Upload one file per request
    JSON=$(curl -F "files[]=@$FILE;filename=$(basename_file "$DESTFILE")" "$URL") || return 1

    if ! match "success" "$JSON"; then
        log_error "upload failed"
        return 1
    fi

    LINK=$(echo "$JSON" | parse 'url' ':"\([^"]*\)\",\"size')
    LINK=${LINK//[\\]/}

    echo "$LINK"
    return 0
}

# List a wupload public folder URL
# $1: wupload url
# stdout: list of links
wupload_list() {
    URL="$1"

    if ! match "${MODULE_WUPLOAD_REGEXP_URL}folder\/" "$URL"; then
        log_error "This is not a folder"
        return 1
    fi

    PAGE=$(curl -L "$URL" | grep "<a href=\"${MODULE_WUPLOAD_REGEXP_URL}file/")

    if ! test "$PAGE"; then
        log_error "Wrong folder link (no download link detected)"
        return 1
    fi

    # First pass: print file names (debug)
    while read LINE; do
        FILENAME=$(echo "$LINE" | parse_quiet 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILENAME"
    done <<< "$PAGE"

    # Second pass: print links (stdout)
    while read LINE; do
        LINK=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$LINK"
    done <<< "$PAGE"

    return 0
}
