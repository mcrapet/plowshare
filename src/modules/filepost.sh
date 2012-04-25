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
AUTH,a:,auth:,USER:PASSWORD,Premium account"
MODULE_FILEPOST_DOWNLOAD_RESUME=yes
MODULE_FILEPOST_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_FILEPOST_LIST_OPTIONS=""

# Static function. Proceed with login (premium)
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
    if match '"captcha":true' "$LOGIN_RESULT"; then
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
        elif match '"succes":true' "$LOGIN_RESULT"; then
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
    local PAGE FILE_NAME JSON SID CODE FILE_PASS TID JSURL WAIT

    if [ -n "$AUTH" ]; then
        filepost_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return
        PAGE=$(curl -L -b "$COOKIEFILE" "$URL") || return

        # duplicated code (see below)
        if matchi 'file not found' "$PAGE"; then
            return $ERR_LINK_DEAD
        fi

        FILE_URL=$(echo "$PAGE" | parse '\/get_file\/' "('\(http[^']*\)") || return
        FILE_NAME=$(echo "$PAGE" | parse '<title>' ': Download \(.*\) - fast')

        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0

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
    elif matchi 'files over 400MB can be' "$PAGE" || \
        matchi 'premium membership is required' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    test "$CHECK_LINK" && return 0

    FILE_NAME=$(echo "$PAGE" | parse '<title>' ': Download \(.*\) - fast')
    FILE_PASS=

    CODE=$(echo "$URL" | parse '\/files\/' 'files\/\([^/]*\)') || return
    TID="t$RANDOM"

    # Cookie is just needed for SID
    SID=$(parse_cookie 'SID' < "$COOKIEFILE") || return
    JSURL="$BASE_URL/files/get/?SID=$SID&JsHttpRequest=$(date +%s000)-xml"

    log_debug "code=$CODE, sid=$SID"

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
    FILE_URL=$(echo "$JSON" | \
        parse '"answer":' '"link":[[:space:]]*"\([^"]*\)"') || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
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
    local PAGE LINKS FOLDERS FILE_URL RET

    RET=$ERR_LINK_DEAD
    PAGE=$(curl -L "$URL") || return
    LINKS=$(echo "$PAGE" | grep 'class="dl"')

    #  Print links (stdout)
    while read LINE; do
        test "$LINE" || continue
        FILE_URL=$(echo "$LINE" | parse_attr '.' 'href')
        echo "$FILE_URL"
    done <<< "$LINKS"

    test "$LINKS" && RET=0

    if test "$REC"; then
        FOLDERS=$(echo "$PAGE" | grep 'class="dl"')
        while read LINE; do
            test "$LINE" || continue
            FILE_URL=$(echo "$LINE" | parse_attr '.' 'href')
            log_debug "entering sub folder: $FILE_URL"
            filepost_list_rec "$REC" "$FILE_URL" && RET=0
        done <<< "$FOLDERS"
    fi

    return $RET
}
