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

MODULE_FILEPOST_DOWNLOAD_OPTIONS=""
MODULE_FILEPOST_DOWNLOAD_RESUME=yes
MODULE_FILEPOST_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_FILEPOST_LIST_OPTIONS=""

# $1: cookie file
# $2: filepost.com url
# stdout: real file download link
filepost_download() {
    local COOKIEFILE="$1"
    local URL="$2"
    local PAGE FILE_NAME JSON SID CODE FILE_PASS TID JSURL WAIT

    if [ -s "$COOKIEFILE" ]; then
        PAGE=$(curl -L -b "$COOKIEFILE" "$URL") || return
    else
        PAGE=$(curl -L -c "$COOKIEFILE" "$URL") || return
    fi

    if matchi 'file not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    FILE_NAME=$(echo "$PAGE" | parse_quiet '<title>' ': Download \(.*\) - fast')
    FILE_PASS=

    CODE=$(echo "$URL" | parse '\/files\/' 'files\/\([^/]*\)') || return
    TID="t${RANDOM}"

    # Cookie is just needed for SID
    SID=$(parse_cookie 'SID' < "$COOKIEFILE")
    JSURL="http://filepost.com/files/get/?SID=$SID&JsHttpRequest=$(date +%s000)-xml"

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
        recaptcha_nack $ID
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    recaptcha_ack $ID
    log_debug "correct captcha"

    # {"id":"12345","js":{"answer":{"link":"http:\/\/fs122.filepost.com\/get_file\/...\/"}},"text":""}
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
    local REC="$1"
    local URL="$2"
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
