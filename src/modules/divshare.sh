#!/bin/bash
#
# divshare.com module
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

MODULE_DIVSHARE_REGEXP_URL="http://\(www\.\)\?divshare\.com/download"

MODULE_DIVSHARE_DOWNLOAD_OPTIONS=""
MODULE_DIVSHARE_DOWNLOAD_RESUME=no
MODULE_DIVSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_DIVSHARE_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"
MODULE_DIVSHARE_UPLOAD_REMOTE_SUPPORT=no


# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
divshare_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE STATUS NAME

    LOGIN_DATA='user_email=$USER&user_password=$PASSWORD&login_submit=Log+in+%3E'
    PAGE=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
       "$BASE_URL/login" -b "$COOKIE_FILE" -L) || return

    STATUS=$(parse_cookie_quiet 'ds_login_2' < "$COOKIE_FILE")
    [ -n "$STATUS" ] || return $ERR_LOGIN_FAILED

    NAME=$(echo "$PAGE" | parse 'logged in as' \
        '^[[:space:]]*logged in as \(.\+\) |') || return

    log_debug "Successfully logged in as member '$NAME'"
}

# Output a divshare file download URL
# $1: cookie file
# $2: divshare url
# stdout: real file download link
divshare_download() {
    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://www.divshare.com'
    local PAGE REDIR_URL WAIT_PAGE WAIT_TIME FILE_URL FILENAME

    PAGE=$(curl -c "$COOKIEFILE" "$URL") || return

    if match '<div id="fileInfoHeader">File Information</div>'; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Uploader can disable audio/video download (only streaming is available)
    REDIR_URL=$(echo "$PAGE" | parse_attr_quiet 'btn_download_new' 'href') || {
        log_error "content download not allowed";
        return $ERR_LINK_DEAD;
    }

    if ! match_remote_url "$REDIR_URL"; then
        WAIT_PAGE=$(curl -b "$COOKIEFILE" "${BASE_URL}$REDIR_URL")
        WAIT_TIME=$(echo "$WAIT_PAGE" | parse_quiet 'http-equiv="refresh"' 'content="\([^;]*\)')
        REDIR_URL=$(echo "$WAIT_PAGE" | parse 'http-equiv="refresh"' 'url=\([^"]*\)')

        # Usual wait time is 15 seconds
        wait $((WAIT_TIME)) seconds || return

        PAGE=$(curl -b "$COOKIEFILE" "${BASE_URL}$REDIR_URL") || return
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr 'btn_download_new' 'href') || return
    FILENAME=$(echo "$PAGE" | parse_tag title)

    echo $FILE_URL
    echo "${FILENAME% - DivShare}"
}

# Upload a file to DivShare
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: divshare download link
divshare_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.divshare.com'
    local PAGE UP_URL SIZE MAX_SIZE LINK

    test "$AUTH_FREE" || return $ERR_LINK_NEED_PERMISSIONS
    divshare_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

    # Capture (+ follow) redirect to the actual upload server
    PAGE=$(curl -b "$COOKIE_FILE" -L -i "$BASE_URL/upload") || return
    UP_URL=$(echo "$PAGE" | grep_http_header_location) || return
    MAX_SIZE=$(echo "$PAGE" | \
        parse_form_input_by_name_quiet 'MAX_FILE_SIZE') || return

    test "$MAX_SIZE" || MAX_SIZE=$(( 200 * 1024 * 1024 ))

    # Check file size
    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Upload file
    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -F 'upload_method=php' -F "MAX_FILE_SIZE=$MAX_SIZE" \
        -F "file1=@$FILE;filename=$DEST_FILE" \
        -F 'description[0]=' \
        -F 'file2=;type=application/octet-stream;filename=' \
        -F 'file2_description=Description' \
        -F 'file3=;type=application/octet-stream;filename=' \
        -F 'file3_description=Description' \
        -F 'file4=;type=application/octet-stream;filename=' \
        -F 'file4_description=Description' \
        -F 'file5=;type=application/octet-stream;filename=' \
        -F 'file5_description=Description' \
        -F 'gallery_id=0' -F 'gallery_title=' -F 'gallery_password=' \
        -F 'email_to=' -F 'terms=on' "$UP_URL") || return

    # <img src="http://divshare.com/images/v4/upload/files_uploaded_text.png">
    # Share them with this links.
    if match 'Share them with this links.' "$PAGE"; then

        # Extract link
        LINK=$(echo "$PAGE" | parse_tag "$BASE_URL/download/" 'a') || return

    # <title>DivShare - Upload Error</title>
    elif match '<title>.*Upload Error</title>' "$PAGE"; then

        # Sorry, we can't upload a file of this type. Some files, particularly executable ones, pose a security risk to our server and our users.
        if match "Sorry, we can't upload a file of this type." "$PAGE"; then
            log_error 'Banned file type. Try changing the extension.'

        # Sorry, we couldn't process the image "pic.jpg" &mdash; it may not be a valid JPG, GIF or PNG file.
        elif match "Sorry, we couldn't process the image" "$PAGE"; then
            log_error 'Server refuses to accept corrupt image file.'

        else
            local ERROR=$(echo "$PAGE" | \
                parse_quiet '<div class="errors_v4">' '^\(.*\)$')
            log_error "Site reports upload error: $ERROR"
        fi

        return $ERR_FATAL

    else
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    # Output link and delete link (which is actually the same)
    echo "$LINK"
    echo "$LINK"
}
