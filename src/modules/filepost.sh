#!/bin/bash
#
# filepost.com module
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

MODULE_FILEPOST_REGEXP_URL="https\?://\(www\.\)\?filepost\.com/"

MODULE_FILEPOST_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,EMAIL:PASSWORD,User account"
MODULE_FILEPOST_DOWNLOAD_RESUME=yes
MODULE_FILEPOST_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_FILEPOST_UPLOAD_OPTIONS="
AUTH,a:,auth:,EMAIL:PASSWORD,User account (mandatory)"
MODULE_FILEPOST_UPLOAD_REMOTE_SUPPORT=no

MODULE_FILEPOST_LIST_OPTIONS=""

# Static function. Proceed with login (free or premium)
filepost_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT STATUS SID

    # Get SID cookie entry
    # Note: Giving SID as cookie input seems optional
    #       (adding "-b $COOKIE_FILE" as last argument to post_login is not required)
    curl -c "$COOKIE_FILE" -o /dev/null "$BASE_URL"
    SID=$(parse_cookie_quiet 'SID' < "$COOKIE_FILE")

    LOGIN_DATA='email=$USER&password=$PASSWORD&remember=on&recaptcha_response_field='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/general/login_form/?SID=$SID&JsHttpRequest=$(date +%s000)-xml") || return

    # JsHttpRequest is important to get JSON answers, if unused, we get an extra
    # cookie entry named "error" (in case of incorrect login)

    # Sometimes prompts for reCaptcha (like depositfiles)
    # {"id":"1234","js":{"answer":{"captcha":true}},"text":""}
    if match_json_true 'captcha' "$LOGIN_RESULT"; then
        log_debug "recaptcha solving required for login"

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6Leu6cMSAAAAAFOynB3meLLnc9-JYi-4l94A6cIE'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        LOGIN_DATA="email=\$USER&password=\$PASSWORD&remember=on&recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD"
        LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/general/login_form/?SID=$SID&JsHttpRequest=$(date +%s000)-xml") || return

        # {"id":"1234","js":{"error":"Incorrect e-mail\/password combination"},"text":""}
        if match 'Incorrect e-mail' "$LOGIN_RESULT"; then
            captcha_ack $ID
            return $ERR_LOGIN_FAILED
        # {"id":"1234","js":{"answer":{"success":true},"redirect":"http:\/\/filepost.com\/"},"text":""}
        elif match_json_true 'success' "$LOGIN_RESULT"; then
            captcha_ack $ID
            log_debug "correct captcha"
        # {"id":"1234","js":{"answer":{"captcha":true},"error":"The code you entered is incorrect. Please try again."},"text":""}
        else
            captcha_nack $ID
            log_debug "reCaptcha error"
            return $ERR_CAPTCHA
        fi
    fi

    # If successful, two entries are added into cookie file: u and remembered_user
    STATUS=$(parse_cookie_quiet 'remembered_user' < "$COOKIE_FILE")
    if [ -z "$STATUS" ]; then
        return $ERR_LOGIN_FAILED
    fi
}

# $1: cookie file
# $2: filepost.com url
# stdout: real file download link
filepost_download() {
    eval "$(process_options filepost "$MODULE_FILEPOST_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://filepost.com'
    local PAGE FILE_NAME JSON SID CODE FILE_PASS TID JSURL WAIT ROLE

    if [ -n "$AUTH" ]; then
        filepost_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return
        PAGE=$(curl -L -b "$COOKIEFILE" "$URL") || return

        # duplicated code (see below)
        if matchi 'file not found' "$PAGE"; then
            return $ERR_LINK_DEAD
        fi

        ROLE=$(echo "$PAGE" | parse_tag 'Account type' span) || return
        if [ "$ROLE" != 'Free' ]; then
            FILE_URL=$(echo "$PAGE" | parse '/get_file/' "('\(http[^']*\)") || return
            FILE_NAME=$(echo "$PAGE" | parse '<title>' ': Download \(.*\) - fast')

            echo "$FILE_URL"
            echo "$FILE_NAME"
            return 0
        fi
    elif [ -s "$COOKIEFILE" ]; then
        PAGE=$(curl -L -b "$COOKIEFILE" "$URL") || return
    else
        PAGE=$(curl -L -c "$COOKIEFILE" "$URL") || return
    fi

    # <div class="file_info file_info_deleted">
    if matchi 'file not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    # <div class="file_info file_info_temp_unavailable">
    # We are sorry, the server where this file is located is currently unavailable,
    # but should be recovered soon. Please try to download this file later.
    elif matchi 'is currently unavailable' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif matchi 'files over 400MB can be' "$PAGE"; then
        return $ERR_SIZE_LIMIT_EXCEEDED
    elif matchi 'premium membership is required' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    test "$CHECK_LINK" && return 0

    FILE_NAME=$(echo "$PAGE" | parse '<title>' ': Download \(.*\) - fast')
    FILE_PASS=

    CODE=$(echo "$URL" | parse '/files/' 'files/\([^/]*\)') || return
    TID=t$(random d 4)

    # Cookie is just needed for SID
    SID=$(parse_cookie 'SID' < "$COOKIEFILE") || return
    JSURL="$BASE_URL/files/get/?SID=$SID&JsHttpRequest=$(date +%s000)-xml"

    log_debug "code=$CODE, sid=$SID, tid=$TID"

    JSON=$(curl --data \
        "action=set_download&code=$CODE&token=$TID" "$JSURL") || return

    # {"id":"12345","js":{"answer":{"wait_time":"60"}},"text":""}
    WAIT=$(echo "$JSON" | parse 'wait_time' \
        'wait_time"[[:space:]]*:[[:space:]]*"\([^"]*\)')

    if test -z "$WAIT"; then
        log_error "Cannot get wait time"
        log_debug "$JSON"
        return $ERR_FATAL
    fi

    wait $WAIT seconds || return

    # reCaptcha part
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6Leu6cMSAAAAAFOynB3meLLnc9-JYi-4l94A6cIE'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    JSON=$(curl --data \
        "code=$CODE&file_pass=$FILE_PASS&recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD&token=$TID" \
        "$JSURL") || return

    # {"id":"12345","js":{"error":"You entered a wrong CAPTCHA code. Please try again."},"text":""}
    if matchi 'wrong CAPTCHA code' "$JSON"; then
        captcha_nack $ID
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug "correct captcha"

    # {"id":"12345","js":{"answer":{"link":"http:\/\/fs122.filepost.com\/get_file\/...\/"}},"text":""}
    # {"id":"12345","js":{"error":"f"},"text":""}
    local ERR=$(echo "$JSON" | parse_json_quiet 'error')
    if [ -n "$ERR" ]; then
        # You still need to wait for the start of your download"
        if match 'need to wait' "$ERR"; then
            return $ERR_LINK_TEMP_UNAVAILABLE
        else
            log_error "remote error: $ERR"
            return $ERR_FATAL
        fi
    fi

    FILE_URL=$(echo "$JSON" | parse_json link) || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to filepost
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download_url
filepost_upload() {
    eval "$(process_options filepost "$MODULE_FILEPOST_UPLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='https://filepost.com'
    local PAGE ROLE SERVER MAX_SIZE SID DONE_URL DATA FID

    test "$AUTH" || return $ERR_LINK_NEED_PERMISSIONS

    filepost_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    PAGE=$(curl -L -b "$COOKIE_FILE" "$BASE_URL/files/upload") || return

    ROLE=$(echo "$PAGE" | parse_tag 'Account type' span) || return
    log_debug "Account type: $ROLE"

    SERVER=$(echo "$PAGE" | parse '[[:space:]]upload_url' ":[[:space:]]'\([^']*\)") || return
    MAX_SIZE=$(echo "$PAGE" | parse 'max_file_size:' ":[[:space:]]*\([^,]\+\)") || return

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    SID=$(echo "$PAGE" | parse 'SID:' ":[[:space:]]*'\([^']*\)") || return
    DONE_URL=$(echo "$PAGE" | parse 'done_url:' ":[[:space:]]*'\([^']*\)") || return

    DATA=$(curl_with_log --user-agent 'Shockwave Flash' \
        -F "Filename=$DESTFILE" \
        -F "SID=$SID" \
        -F "file=@$FILE;filename=$DESTFILE" \
        -F 'Upload=Submit Query' \
        "$SERVER") || return

    # new Object({"answer":"4c8e89fa"})
    FID=$(echo "$DATA" | parse_json answer) || return
    log_debug "file id: $FID"

    # Note: Account cookie required here
    DATA=$(curl -b "$COOKIE_FILE" -b "SID=$SID" "$DONE_URL$FID") || return

    echo "$DATA" | parse_attr 'id="down_link' value || return
    echo "$DATA" | parse_attr 'id="edit_link' value || return
}

# List a filepost web folder URL
# $1: filepost URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
filepost_list() {
    if ! match 'filepost\.com/folder/' "$1"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    filepost_list_rec "$2" "$1" || return
}

# static recursive function
# $1: recursive flag
# $2: web folder URL
filepost_list_rec() {
    local REC=$1
    local URL=$2
    local PAGE LINKS NAMES RET LINE

    RET=$ERR_LINK_DEAD
    PAGE=$(curl -L "$URL") || return

    if match 'class="dl"' "$PAGE"; then
        LINKS=$(echo "$PAGE" | parse_all_attr 'class="dl"' href)
        NAMES=$(echo "$PAGE" | parse_all_tag 'class="file \(video\|image\|disk\|archive\)"' a)
        list_submit "$LINKS" "$NAMES" && RET=0
    fi

    if test "$REC"; then
        LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'class="file folder"' href)
        while read LINE; do
            test "$LINE" || continue
            log_debug "entering sub folder: $LINE"
            filepost_list_rec "$REC" "$LINE" && RET=0
        done <<< "$LINKS"
    fi

    return $RET
}
