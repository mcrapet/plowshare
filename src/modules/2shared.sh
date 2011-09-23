#!/bin/bash
#
# 2share.com module
# Copyright (c) 2010-2011 Plowshare team
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
MODULE_2SHARED_DELETE_OPTIONS=""

# Output a 2shared file download URL
# $1: cookie file (unused here)
# $2: 2shared url
# stdout: real file download link
2shared_download() {
    local URL="$2"
    local PAGE

    PAGE=$(curl "$URL") || return

    if match "file link that you requested is not valid" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_URL=$(echo "$PAGE" | parse 'window.location' "='\([^']*\)") || return $ERR_FATAL
    test "$CHECK_LINK" && return 0

    FILENAME=$(echo "$PAGE" | parse '<title>' 'download *\([^<]*\)') || true

    echo "$FILE_URL"
    test "$FILENAME" && echo "$FILENAME"
}

# Upload a file to 2shared.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: 2shared.com download + admin link
2shared_upload() {
    eval "$(process_options 2shared "$MODULE_2SHARED_UPLOAD_OPTIONS" "$@")"

    local FILE="$2"
    local DESTFILE="$3"
    local UPLOADURL="http://www.2shared.com/"

    log_debug "downloading upload page: $UPLOADURL"
    DATA=$(curl "$UPLOADURL") || return
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

    DATA=$(curl "$UPLOADURL/$COMPLETE") || return
    local URL=$(echo "$DATA" | parse 'name="downloadLink"' "\(http:[^<]*\)")
    local ADMIN=$(echo "$DATA" | parse 'name="adminLink"' "\(http:[^<]*\)")

    echo "$URL ($ADMIN)"
}

# Delete a file uploaded to 2shared
# $1: ADMIN_URL
2shared_delete() {
    eval "$(process_options 2shared "$MODULE_2SHARED_DELETE_OPTIONS" "$@")"

    local URL="$1"
    local BASE_URL="http://www.2shared.com"

    # Without cookie, it does not work
    COOKIES=$(create_tempfile)
    ADMIN_PAGE=$(curl -c $COOKIES "$URL")

    if ! match 'Delete File' "$ADMIN_PAGE"; then
        log_error "File not found"
        rm -f $COOKIES
        return $ERR_LINK_DEAD
    else
        FORM=$(grep_form_by_name "$ADMIN_PAGE" 'theForm') || {
            log_error "can't get delete form, website updated?";
            rm -f $COOKIES
            return $ERR_FATAL
        }

        local ACTION=$(echo "$FORM" | parse_form_action)
        local DL_LINK=$(echo "$FORM" | parse_form_input_by_name 'downloadLink' | uri_encode_strict)
        local AD_LINK=$(echo "$FORM" | parse_form_input_by_name 'adminLink' | uri_encode_strict)

        curl -b $COOKIES --referer "$URL" \
            --data "resultMode=2&password=&description=&publisher=&downloadLink=${DL_LINK}&adminLink=${AD_LINK}" \
            "$BASE_URL$ACTION" >/dev/null
        # Can't parse for success, we get redirected to main page

        rm -f $COOKIES
    fi
}
