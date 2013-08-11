#!/bin/bash
#
# ziddu.com module
# Copyright (c) 2013 Plowshare team
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

MODULE_ZIDDU_REGEXP_URL="https\?://\(www\.\)\?ziddu\.com/"

MODULE_ZIDDU_DOWNLOAD_OPTIONS=""
MODULE_ZIDDU_DOWNLOAD_RESUME=no
MODULE_ZIDDU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_ZIDDU_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_ZIDDU_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_ZIDDU_UPLOAD_REMOTE_SUPPORT=no

MODULE_ZIDDU_DELETE_OPTIONS=""
MODULE_ZIDDU_PROBE_OPTIONS=""

# Static function. Proceed with login (free)
ziddu_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL='http://www.ziddu.com'
    local LOGIN_DATA LOGIN_RESULT LOCATION

    LOGIN_DATA='email=$USER&password=$PASSWORD&cookie=&Submit=%C2%A0Login%C2%A0&action=LOGIN&uid=&red='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.php" "-i") || return

    LOCATION=$(echo "$LOGIN_RESULT" | grep_http_header_location_quiet) || return

    if ! match '^upload\.php' "$LOCATION"; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a bitshare file download URL
# $1: cookie file
# $2: ziddu url
# stdout: real file download link
ziddu_download() {
    local COOKIE_FILE=$1
    local URL=$2

    local PAGE LOCATION REFERER BASE_URL
    local CAPTCHA_URL CAPTCHA_IMG
    local FORM_HTML FORM_URL

    # Form 1 data
    local FORM_MEM_ID FORM_MEM_N FORM_LANG
    # Form 2 data
    local FORM_FID FORM_TID FORM_FNAME
    # Temporary file & header
    local TMP_FILE TMP_FILE_H

    if ! match '^http://www\.ziddu\.com/download/\([[:digit:]]\+\)/' "$URL"; then
        log_error "Bad url"
        return $ERR_LINK_DEAD
    fi

    PAGE=$(curl -c "$COOKIE_FILE" -b 'lan=eng' -b "$COOKIE_FILE" -i "$URL") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet) || return

    if match '^/errortracking\.php?msg=File not found' "$LOCATION"; then
        return $ERR_LINK_DEAD
    fi

    # Bad url or other error
    if match '^/errortracking\.php?msg=' "$LOCATION"; then
        log_error "ERROR MSG: '${LOCATION:23}'"
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" -1) || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_MEM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'mmemid') || return
    FORM_MEM_N=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'mname') || return
    FORM_LANG=$(echo "$FORM_HTML" | parse_form_input_by_name 'lang') || return

    # Writing cookies again, new domain
    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -e "$URL" \
        -d "mmemid=$FORM_MEM_ID" \
        -d "mname=$FORM_MEM_N" \
        -d "lang=$FORM_LANG" \
        -d "Submit=Download" \
        "$FORM_URL") || return

    # http://downloads.ziddu.com/downloadfile/*
    REFERER=$FORM_URL
    BASE_URL=$(basename_url "$FORM_URL")

    FORM_HTML=$(grep_form_by_order "$PAGE" -1) || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_FID=$(echo "$FORM_HTML" | parse_form_input_by_name 'fid') || return
    FORM_TID=$(echo "$FORM_HTML" | parse_form_input_by_name 'tid') || return
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname') || return

    CAPTCHA_URL=$(echo "$FORM_HTML" | parse_attr 'img' 'src') || return
    CAPTCHA_IMG=$(create_tempfile '.jpg') || return

    # Get new image captcha (cookie is mandatory)
    curl -b "$COOKIE_FILE" -e "$REFERER" -o "$CAPTCHA_IMG" "$BASE_URL$CAPTCHA_URL" || return

    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG") || return
    { read WORD; read ID; } <<<"$WI"
    rm -f "$CAPTCHA_IMG"

    TMP_FILE=$(create_tempfile '.ziddu') || return
    TMP_FILE_H=$(create_tempfile '.ziddu_h') || return

    # Need to download now, no other way to check captcha
    curl_with_log -b "$COOKIE_FILE" -e "$REFERER" \
        -D "$TMP_FILE_H" \
        -o "$TMP_FILE" \
        -d "fid=$FORM_FID" \
        -d "tid=$FORM_TID" \
        -d "securitycode=$WORD" \
        -d "fname=$FORM_FNAME" \
        -d "clientos=windows" \
        -d "Keyword=Ok" \
        -d "submit=Download" \
        "$BASE_URL$FORM_URL" || return

    if  match "text/html" $(cat "$TMP_FILE_H" | grep_http_header_content_type) ; then
        rm -f "$TMP_FILE_H"
        rm -f "$TMP_FILE"
        return $ERR_CAPTCHA
    fi

    FILE_NAME=$(cat "$TMP_FILE_H" | grep_http_header_content_disposition) || return

    rm -f "$TMP_FILE_H"

    echo "file://$TMP_FILE"
    echo "$FILE_NAME"
}

# Upload a file to ziddu.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
ziddu_upload() {
    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://www.ziddu.com'
    local PAGE LOCATION REFERER
    local FORM_HTML FORM_URL LINK_DL LINK_DEL
    local FORM_MEM_ID FORM_MEM_N FORM_MEM_M FORM_LANG

    if test "$AUTH"; then
        ziddu_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
        
        PAGE=$(curl -b "$COOKIE_FILE" -e "$BASE_URL/login.php" "$BASE_URL/upload.php") || return
        
        FORM_HTML=$(grep_form_by_name "$PAGE" 'upform') || return
        FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
        FORM_MEM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'mmemid') || return
        FORM_MEM_N=$(echo "$FORM_HTML" | parse_form_input_by_name 'mname') || return
        FORM_MEM_M=$(echo "$FORM_HTML" | parse_form_input_by_name 'memail') || return
        FORM_LANG=$(echo "$FORM_HTML" | parse_form_input_by_name 'lang') || return
        
        PAGE=$(curl -b "$COOKIE_FILE" -e "$BASE_URL/upload.php" \
            -d "mmemid=$FORM_MEM_ID" \
            -d "mname=$FORM_MEM_N" \
            -d "memail=$FORM_MEM_M" \
            -d "lang=$FORM_LANG" \
            "$FORM_URL") || return

        REFERER=$FORM_URL
    else
        PAGE=$(curl -c "$COOKIE_FILE" -b 'lan=eng' -b "$COOKIE_FILE" -e "$BASE_URL/index.php" "http://uploads.ziddu.com/uploadanon.php") || return
        REFERER='http://uploads.ziddu.com/uploadanon.php'
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'form_upload') || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    # Will be empty on anon upload
    FORM_MEM_M=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'memail') || return

    PAGE=$(curl_with_log -b "$COOKIE_FILE" -e "$REFERER" -i \
        -F "upfile_0=@$FILE;filename=$DESTFILE" \
        -F "memail=$FORM_MEM_M" \
        "http://uploads.ziddu.com/$FORM_URL") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet) || return

    # Check upload finished page link
    if match '^http://www\.ziddu\.com/finished\(anon\)\?\.php.*?sub=done' "$LOCATION"; then
        return $ERR_FATAL
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -e "$REFERER" "$LOCATION") || return

    if test "$AUTH"; then
        LINK_DL=$(echo "$PAGE" | parse '<a href="http://www.ziddu.com/download/' 'href="\([^"]*\)"') || return
        
        echo "$LINK_DL"
        return 0
    fi

    LINK_DL=$(echo "$PAGE" | parse 'acclink' 'value=\([^[:space:]]*\)') || return
    LINK_DEL=$(echo "$PAGE" | parse 'dellink' 'value=\([^[:space:]]*\)') || return

    # Cannot parse value from <input type="hidden" value=http://www.ziddu.com/download/12345678/file.name.ext.html name="acclink"  id="acclink" size="50"/ >
    #FORM_HTML=$(grep_form_by_order "$PAGE" -1) || return
    #FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    #LINK_DL=$(echo "$FORM_HTML" | parse_form_input_by_name 'acclink') || return
    #LINK_DEL=$(echo "$FORM_HTML" | parse_form_input_by_name 'dellink') || return

    echo "$LINK_DL"
    echo "$LINK_DEL"
}

# Delete a file uploaded to ziddu.com
# $1: cookie file (unused here)
# $2: delete url
ziddu_delete() {
    local URL=$2
    local PAGE CONFIRM

    if ! match '^http://www\.ziddu\.com/delete/\([[:digit:]]\+\)/\([[:digit:]]\+\)/' "$URL"; then
        log_error "Bad url"
        return $ERR_LINK_DEAD
    fi

    PAGE=$(curl -b 'lan=eng' "$URL") || return

    # Invalid link - File not found
    if match 'Not a valid link Or May be File Deleted' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    CONFIRM=$(echo "$PAGE" | parse 'http://www\.ziddu\.com/delete\.php' "href='\([^']*\)'") || return

    PAGE=$(curl -b 'lan=eng' "$CONFIRM") || return

    if match 'File deleted Successfully' "$PAGE"; then
        return 0
    fi

    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: ziddu url
# $3: requested capability list
# stdout: 1 capability per line
ziddu_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE LOCATION FILE_SIZE REQ_OUT

    if ! match '^http://www\.ziddu\.com/download/\([[:digit:]]\+\)/' "$URL"; then
        log_error "Bad url"
        return $ERR_LINK_DEAD
    fi

    PAGE=$(curl -b 'lan=eng' -i "$URL") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet) || return

    if match '^/errortracking\.php?msg=File not found' "$LOCATION"; then
        return $ERR_LINK_DEAD
    fi

    # Bad url or other error
    if match '^/errortracking\.php?msg=' "$LOCATION"; then
        log_error "ERROR MSG: '${LOCATION:23}'"
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    # Parse file name from download form action
    if [[ $REQ_IN = *f* ]]; then
        echo "$PAGE" | parse 'form action' 'http://downloads\.ziddu\.com/downloadfile/.*\?/\(.*\?\)\.html"' | uri_decode &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse 'span class' \
            '>\([[:digit:].]\+[[:space:]][KMG]\?B\)\(ytes\)\?[[:space:]]\?<') &&
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
