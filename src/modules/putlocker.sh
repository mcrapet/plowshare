#!/bin/bash
#
# putlocker.com module
# Copyright (c) 2012-2013 Plowshare team
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

MODULE_PUTLOCKER_REGEXP_URL='http://\(www\.\)\?putlocker\.com/file/'

MODULE_PUTLOCKER_DOWNLOAD_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_PUTLOCKER_DOWNLOAD_RESUME=yes
MODULE_PUTLOCKER_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_PUTLOCKER_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_PUTLOCKER_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account (mandatory)"
MODULE_PUTLOCKER_UPLOAD_REMOTE_SUPPORT=no

MODULE_PUTLOCKER_PROBE_OPTIONS=""

# Output a putlocker file download URL
# $1: cookie file
# $2: putlocker url
# stdout: real file download link
putlocker_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.putlocker.com'
    local FILE_URL FILENAME PAGE HASH REL_PATH

    PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return

    # If link is dead, site sends a 302 redirect header to ../?404
    # so the page body is empty:
    if [ -z "$PAGE" ]; then
        return $ERR_LINK_DEAD
    fi


    HASH=$(parse_form_input_by_name 'hash' <<< "$PAGE") || return

    # After the POST to itself it redirects to itself
    PAGE=$(curl -b "$COOKIE_FILE" --data "hash=$HASH" \
        --data 'confirm=Continue+as+Free+User' \
        --location "$URL") || return

    # This file requires a password. Please enter it.
    if match 'file_password' "$PAGE"; then
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "file_password=$LINK_PASSWORD" "$URL") || return

        # Status is always 302 with empty "Location:"
        # So, we reload main page
        PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

        if match 'This password is not correct' "$PAGE"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        fi
    fi

    # Audio content
    if match 'jPlayer(' "$PAGE"; then
        # this.element.jPlayer("setFile", "/get_file.php?id=...");
        REL_PATH=$(parse 'jPlayer("setFile"' '",[[:space:]]*"\([^"]*\)' <<< "$PAGE") || return
    else
        # First occurrence
        REL_PATH=$(parse_attr 'Download File' 'href' <<< "$PAGE") || return
    fi

    # If server is "down for maintenance", a 302 status
    # is returned with an empty "Location: "
    FILE_URL=$(curl --head -b "$COOKIE_FILE" "$BASE_URL$REL_PATH" | \
        grep_http_header_location) || return

    if ! match_remote_url "$FILE_URL"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FILENAME=$(parse_tag title <<< "$PAGE")

    echo "$FILE_URL"
    echo "${FILENAME% | PutLocker}"
}

# Upload a file to putlocker.com
# Use API: http://www.putlocker.com/apidocs.php
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download
putlocker_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r API_URL='http://upload.putlocker.com/uploadapi.php'
    local -r UP_URL='http://www.putlocker.com/upload_form.php'
    local PAGE SRV_CGI SIZE_LIMIT SESSION AUTH_HASH DONE_ID

    if [ -n "$AUTH_FREE" ]; then
        local DATA MSG USER PASSWORD DL_URL
        split_auth "$AUTH_FREE" USER PASSWORD || return

        DATA=$(curl_with_log \
            -F "file=@$FILE;filename=$DESTFILE" \
            -F "user=$USER" \
            -F "password=$PASSWORD" \
            -F 'convert=0' \
            "$API_URL") || return

        # Check for temporary errors
        if [ "$DATA" = 'Uploading is current disabled' ]; then
            log_error 'Remote server error, maybe due to overload.'
            echo 180 # arbitrary time
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        MSG=$(parse_tag message <<< "$DATA") || return

        if match 'File Uploaded Successfully' "$MSG"; then
            DL_URL=$(parse_tag link <<< "$DATA") || return
            echo "$DL_URL"
            return 0
        elif match 'Wrong username or password' "$MSG"; then
            return $ERR_LOGIN_FAILED
        fi

        log_error "Unexpected status: $MSG"
        return $ERR_FATAL
    fi

    PAGE=$(curl "$UP_URL") || return

    # Check for temporary errors
    # Uploading is Currently Disabled for Maintenance.
    if match 'uploading_disabled' "$PAGE"; then
        log_error 'Remote server error, maybe due to overload.'
        echo 180 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    SRV_CGI=$(echo "$PAGE" | parse "'script'" ":[[:space:]]*'\([^']\+\)") || return
    SIZE_LIMIT=$(echo "$PAGE" | parse "'sizeLimit'" ":[[:space:]]*\([^,]\+\)") || return
    SESSION=$(echo "$PAGE" | parse 'scriptData' "'session':[[:space:]]*'\([^']*\)") || return
    AUTH_HASH=$(echo "$PAGE" | parse 'scriptData' "'auth_hash':[[:space:]]*'\([^']*\)") || return
    DONE_ID=$(echo "$PAGE" | parse 'done=' "e=\([^']*\)") || return

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$SIZE_LIMIT" ]; then
        log_debug "file is bigger than $SIZE_LIMIT"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Uses Uploadify v2.1.4 (jquery.uploadify) like filebox
    DATA=$(curl_with_log \
        -F "Filename=$DESTFILE" \
        -F 'folder=/' -F 'do_convert=1' -F 'fileext=*' \
        -F "session=$SESSION" \
        -F "auth_hash=$AUTH_HASH" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        -F 'Upload=Submit Query' \
        "$SRV_CGI") || return

    if [ "$DATA" = 'cool story bro' ]; then
        PAGE=$(curl --get -d "done=$DONE_ID" "$UP_URL") || return
        DATA=$(echo "$PAGE" | parse_attr 'Just Show' href) || return
        PAGE=$(curl -b "upload_hash=$DONE_ID" \
            "http://www.putlocker.com/$DATA") || return

        DL_URL=$(echo "$PAGE" | parse '<textarea' '^\(.*\)$' 1) || return
        echo "${DL_URL//$'\r'}"
        return 0
    fi

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: putlocker url
# $3: requested capability list
# stdout: 1 capability per line
putlocker_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl "$URL") || return

    # If link is dead, site sends a 302 redirect header to ../?404
    # so the page body is empty:
    if [ -z "$PAGE" ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '=.site-content' '<h1>\([^<]*\)' 2 <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse '=.site-content' \
            '<strong>(\([^<)]*\))<' 2) && translate_size "$FILE_SIZE" && \
                REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
