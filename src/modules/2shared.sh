#!/bin/bash
#
# 2share.com module
# Copyright (c) 2010-2012 Plowshare team
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

MODULE_2SHARED_REGEXP_URL="http://\(www\.\)\?2shared\.com/\(file\|document\|fadmin\|video\|audio\)/"

MODULE_2SHARED_DOWNLOAD_OPTIONS=""
MODULE_2SHARED_DOWNLOAD_RESUME=yes
MODULE_2SHARED_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

MODULE_2SHARED_UPLOAD_OPTIONS=""
MODULE_2SHARED_UPLOAD_REMOTE_SUPPORT=no

MODULE_2SHARED_DELETE_OPTIONS=""

# Output a 2shared file download URL
# $1: cookie file (unused here)
# $2: 2shared url
# stdout: real file download link
2shared_download() {
    local URL=$2
    local PAGE FILE_URL FILENAME

    PAGE=$(curl "$URL") || return

    if match "file link that you requested is not valid" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_URL=$(echo "$PAGE" | parse 'window.location' "='\([^']*\)") || return
    test "$CHECK_LINK" && return 0

    FILENAME=$(echo "$PAGE" | parse_tag title | parse . '^\(.*\) 2shared - download$')

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to 2shared.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: 2shared.com download + admin link
2shared_upload() {
    eval "$(process_options 2shared "$MODULE_2SHARED_UPLOAD_OPTIONS" "$@")"

    local FILE=$2
    local DESTFILE=$3
    local UPLOAD_URL='http://www.2shared.com'
    local DATA ACTION COMPLETE STATUS FILE_URL FILE_ADMIN

    log_debug "downloading upload page: $UPLOAD_URL"
    DATA=$(curl "$UPLOAD_URL") || return
    ACTION=$(grep_form_by_name "$DATA" "uploadForm" | parse_form_action) ||
        { log_debug "cannot get upload form URL"; return $ERR_FATAL; }
    COMPLETE=$(echo "$DATA" | parse "uploadComplete" 'location="\([^"]*\)"')

    log_debug "starting file upload: $FILE"
    STATUS=$(curl_with_log \
        -F "mainDC=1" \
        -F "fff=@$FILE;filename=$DESTFILE" \
        "$ACTION") || return

    if ! match "upload has successfully completed" "$STATUS"; then
        log_error "upload failure"
        return $ERR_FATAL
    fi

    DATA=$(curl "$UPLOAD_URL$COMPLETE") || return
    FILE_URL=$(echo "$DATA" | parse 'name="downloadLink"' "\(http:[^<]*\)") || return
    FILE_ADMIN=$(echo "$DATA" | parse 'name="adminLink"' "\(http:[^<]*\)")

    echo "$FILE_URL"
    echo
    echo "$FILE_ADMIN"
}

# Delete a file uploaded to 2shared
# $1: cookie file
# $2: ADMIN_URL
2shared_delete() {
    eval "$(process_options 2shared "$MODULE_2SHARED_DELETE_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://www.2shared.com'
    local ADMIN_PAGE FORM DL_LINK AD_LINK

    # Without cookie, it does not work
    ADMIN_PAGE=$(curl -c "$COOKIEFILE" "$URL") || return

    if ! match 'Delete File' "$ADMIN_PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM=$(grep_form_by_name "$ADMIN_PAGE" 'theForm') || {
        log_error "can't get delete form, website updated?";
        return $ERR_FATAL;
    }

    DL_LINK=$(echo "$FORM" | parse_form_input_by_name 'downloadLink' | uri_encode_strict)
    AD_LINK=$(echo "$FORM" | parse_form_input_by_name 'adminLink' | uri_encode_strict)

    curl -b "$COOKIEFILE" --referer "$URL" -o /dev/null \
        --data "resultMode=2&password=&description=&publisher=&downloadLink=${DL_LINK}&adminLink=${AD_LINK}" \
        "$URL" || return
    # Can't parse for success, we get redirected to main page
}
