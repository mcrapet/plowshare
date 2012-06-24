#!/bin/bash
#
# rapidgator.net module
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

MODULE_RAPIDGATOR_REGEXP_URL="http://\(www\.\)\?rapidgator\.net/"

MODULE_RAPIDGATOR_UPLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,EMAIL:PASSWORD,Free account
FOLDER,,folder:,FOLDER,Folder to upload files into (account only)"
MODULE_RAPIDGATOR_UPLOAD_REMOTE_SUPPORT=no

MODULE_RAPIDGATOR_DELETE_OPTIONS=""

# Static function. Proceed with login (free)
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
rapidgator_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA HTML EMAIL TYPE STATUS

    LOGIN_DATA='LoginForm[email]=$USER&LoginForm[password]=$PASSWORD&LoginForm[rememberMe]=1'
    HTML=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/auth/login" -L -b "$COOKIE_FILE") || return

    STATUS=$(parse_cookie_quiet 'user__' < "$COOKIE_FILE")
    [ -n "$STATUS" ] || return $ERR_LOGIN_FAILED

    if match 'Account:.*Free' "$HTML"; then
        TYPE='free'
    # XXX - just educated guessing for now!
    elif match 'Account:.*Premium' "$HTML"; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    split_auth "$AUTH_FREE" EMAIL || return
    log_debug "Successfully logged in as $TYPE member '$EMAIL'"

    echo "$TYPE"
}

# Switch language to english
# $1: cookie file
# $2: base URL
rapidgator_switch_lang() {
    curl -b "$1" -c "$1"  -d 'lang=en' -o /dev/null \
        "$2/site/lang" || return
}

# Check if specified folder name is valid.
# When multiple folders wear the same name, first one is taken.
# $1: source code of main page
# $2: folder name selected by user
# stdout: folder ID
rapidgator_check_folder() {
    local -r HTML=$1
    local -r NAME=$2
    local FOLDERS FOL FOL_ID

    # Special treatment for root folder (alsways uses ID "0")
    if [ "$NAME" = 'root' ]; then
        echo 0
        return 0
    fi

    # <option value="ID">NAME</option>
    FOLDERS=$(echo "$HTML" | parse_all_tag option) || return
    if [ -z "$FOLDERS" ]; then
        log_error "No folder found, site updated?"
        return $ERR_FATAL
    fi

    log_debug 'Available folders:' $FOLDERS

    while IFS= read -r FOL; do
        if [ "$FOL" = "$NAME" ]; then
            FOL_ID=$(echo "$HTML" | \
                parse_attr "^<option.*>$FOL</option>" 'value') || return
            echo "$FOL_ID"
            return 0
        fi
    done <<< "$FOLDERS"

    log_error "Invalid folder, choose from:" $FOLDERS
    return $ERR_BAD_COMMAND_LINE
}

# Upload a file to Rapidgator
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
#         delete link
rapidgator_upload() {
    eval "$(process_options rapidgator "$MODULE_RAPIDGATOR_UPLOAD_OPTIONS" "$@")"

    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://rapidgator.net'
    local HTML JSON SESSION_ID START_TIME STATE UP_URL PROG_URL
    local FOLDER_ID=0

    rapidgator_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    # Login (don't care for account type)
    if [ -n "$AUTH_FREE" ]; then
        rapidgator_login "$AUTH_FREE" "$COOKIE_FILE" \
            "$BASE_URL" > /dev/null || return

    # Anonymous upload
    elif [ -n "$FOLDER" ]; then
        log_error 'Folders only available for accounts.'
        return $ERR_BAD_COMMAND_LINE
    fi

    HTML=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        "$BASE_URL/site/index") || return

    # Server sometimes returns an empty page
    if [ -z "$HTML" ]; then
        log_error 'Server sent empty page, may be overloaded.'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # If user chose a folder, check it now
    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(rapidgator_check_folder "$HTML" "$FOLDER") || return
    fi

    # Scrape URLs from site
    UP_URL=$(echo "$HTML" | parse 'var form_url' '"\(.\+\)";') || return
    PROG_URL=$(echo "$HTML" | parse 'var progress_url_srv' \
        '"\(.\+\)";') || return

    log_debug "Upload URL: $UP_URL"
    log_debug "Progress URL: $PROG_URL"
    log_debug "Folder ID: $FOLDER_ID"

    # Session ID is created this way (in uploadwidget.js):
    #   var i, uuid = "";
    #   for (i = 0; i < 32; i++) {
    #       uuid += Math.floor(Math.random() * 16).toString(16);
    #   }
    SESSION_ID=$(random h 32)
    START_TIME=$(date +%s)

    # Upload file
    HTML=$(curl_with_log -b "$COOKIE_FILE" \
        --referer "$BASE_URL/site/index" \
        -F "file=@$FILE;type=application/octet-stream;filename=$DESTFILE" \
        "$UP_URL$SESSION_ID&folder_id=$FOLDER_ID") || return

    # Get download URL
    JSON=$(curl --referer "$BASE_URL/site/index" \
        -H "Origin: $BASE_URL" \
        -H 'Accept: application/json, text/javascript, */*; q=0.01' \
        "$PROG_URL&data%5B0%5D%5Buuid%5D=${SESSION_ID}&data%5B0%5D%5Bstart_time%5D=$START_TIME") || return

    # Check status
    STATE=$(echo "$JSON" | parse_json_quiet 'state')
    if [ "$STATE" != 'done' ]; then
        log_error "Unexpected state: $STATE"
        return $ERR_FATAL
    fi

    echo "$JSON" | parse_json 'download_url' || return
    echo "$JSON" | parse_json 'remove_url'
}

# Delete a file from Rapidgator
# $1: cookie file
# $2: rapidgator (delete) link
rapidgator_delete() {
    eval "$(process_options rapidgator "$MODULE_RAPIDGATOR_DELETE_OPTIONS" "$@")"

    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://rapidgator.net'
    local HTML ID UP_ID

    ID=$(echo "$URL" | parse . '/id/\([^/]\+\)/up_id/') || return
    UP_ID=$(echo "$URL" | parse . '/up_id/\(.\+\)$') || return

    log_debug "ID: '$ID'"
    log_debug "Up_ID: '$UP_ID'"

    rapidgator_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    HTML=$(curl -b "$COOKIE_FILE" "$URL") || return

    if match 'Do you really want to remove' "$HTML"; then
        HTML=$(curl -b "$COOKIE_FILE" -d "id=$ID" -d "up_id=$UP_ID" \
            "$BASE_URL/remove/remove") || return

        if match 'File successfully deleted' "$HTML"; then
            return 0
        fi
    elif match 'File not found' "$HTML"; then
        return $ERR_LINK_DEAD
    fi

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}
