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
