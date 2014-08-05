# Plowshare ziddu.com module
# Copyright (c) 2014 Plowshare team
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

MODULE_ZIDDU_REGEXP_URL='https\?://\(www\.\|downloads\.\)\?ziddu\.com/download/[[:digit:]]\+/'

MODULE_ZIDDU_DOWNLOAD_OPTIONS=""
MODULE_ZIDDU_DOWNLOAD_RESUME=no
MODULE_ZIDDU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_ZIDDU_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_ZIDDU_UPLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account"
MODULE_ZIDDU_UPLOAD_REMOTE_SUPPORT=no

MODULE_ZIDDU_PROBE_OPTIONS=""

# Static function. Proceed with login.
ziddu_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT LOCATION

    LOGIN_DATA='email=$USER&password=$PASSWORD&cookie=&Submit=%C2%A0Login%C2%A0&action=LOGIN&uid=&red='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.php" '-i') || return

    LOCATION=$(echo "$LOGIN_RESULT" | grep_http_header_location_quiet)

    if ! match '^upload\.php' "$LOCATION"; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a ziddu file download URL
# $1: cookie file
# $2: ziddu url
# stdout: real file download link
ziddu_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2

    local BASE_URL='http://downloads.ziddu.com'
    local PAGE LOCATION REFERER
    local CAPTCHA_URL CAPTCHA_IMG
    local FORM_HTML FORM_URL

    # Form 1 data
    local FORM_MEM_ID FORM_MEM_N FORM_LANG
    # Form 2 data
    local FORM_FID FORM_TID FORM_FNAME

    PAGE=$(curl -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" -i "$URL") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)

    # Yes, spaces!
    if match '^/errortracking\.php?msg=File not found\|^/errortracking.php$' "$LOCATION"; then
        return $ERR_LINK_DEAD

    # Bad url or other error
    elif match '^/errortracking\.php?msg=' "$LOCATION"; then
        log_error "Remote error: '${LOCATION:23}'"
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" -1) || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_MEM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'mmemid') || return
    FORM_MEM_N=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'mname')
    FORM_LANG=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'lang') || return

    # Writing cookies again, new domain
    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -e "$URL" \
        -d "mmemid=$FORM_MEM_ID" \
        -d "mname=$FORM_MEM_N" \
        -d "lang=$FORM_LANG" \
        -d "Submit=Download" \
        "$BASE_URL$FORM_URL") || return

    # http://downloads.ziddu.com/downloadfile/*
    REFERER=$BASE_URL$FORM_URL

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

    # Temporary file & HTTP headers
    local TMP_FILE TMP_FILE_H

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

    if  match "text/html" "$(grep_http_header_content_type < "$TMP_FILE_H")"; then
        rm -f "$TMP_FILE_H" "$TMP_FILE"
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    FILE_NAME=$(grep_http_header_content_disposition < "$TMP_FILE_H")
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
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.ziddu.com'
    local PAGE LOCATION
    local FORM_HTML FORM_URL FORM_MEM_M

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    local -r MAX_SIZE=262144000 # 250 MiB
    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Check for allowed file extensions
    if [ "${DEST_FILE##*.}" = "$DEST_FILE" ]; then
        log_error 'Filename has no extension. It is not allowed by hoster, specify an alternate filename.'
        return $ERR_BAD_COMMAND_LINE
    else
        log_debug '*** File extension is checked by hoster. There is a restricted "allowed list", see hoster.'
        log_debug '*** Allowed list (part): 001 3gp 7z apk avi doc exe gz jpg mkv mp3 mp4 mpg rar tgz txt vob wmv zip.'
    fi

    ziddu_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -L -b "$COOKIE_FILE" "$BASE_URL/upload.php") || return

    FORM_HTML=$(grep_form_by_name "$PAGE" 'form_upload') || return
    FORM_URL=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_MEM_M=$(parse_form_input_by_name_quiet 'memail' <<< "$FORM_HTML")

    PAGE=$(curl_with_log -b "$COOKIE_FILE" -i \
        -F "upfile_0=@$FILE;filename=$DEST_FILE" \
        -F "memail=$FORM_MEM_M" \
        "http://uploads.ziddu.com/$FORM_URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    # Check upload finished page link
    if match '^http://www\.ziddu\.com/finished\.php.*?sub=done' "$LOCATION"; then
        return $ERR_FATAL
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$LOCATION") || return

    parse_form_input_by_name_quiet 'txt1' <<< "$PAGE" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: ziddu url
# $3: requested capability list
# stdout: 1 capability per line
ziddu_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE LOCATION FILE_NAME FILE_SIZE REQ_OUT

    PAGE=$(curl -L -i "$URL") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)

    # Yes, spaces!
    if match '^/errortracking\.php?msg=File not found\|^/errortracking.php$' "$LOCATION"; then
        return $ERR_LINK_DEAD

    # Bad url or other error
    elif match '^/errortracking\.php?msg=' "$LOCATION"; then
        log_error "Remote error: '${LOCATION:23}'"
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    # Parse file name from download form action
    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse_form_action <<< "$PAGE" | uri_decode) && \
            echo "$(basename_file "${FILE_NAME%.html}")" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'File Size' 'File Size&nbsp;:&nbsp;\([^&]\+\)' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
