#!/bin/bash
#
# shareonline.biz module
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

MODULE_SHAREONLINE_BIZ_REGEXP_URL="http://\(\www\.\)\?\(share\-online\.biz\|egoshare\.com\)/\(download\.php?id\=\|dl/\)\(\w\)"

MODULE_SHAREONLINE_BIZ_DOWNLOAD_OPTIONS=""
MODULE_SHAREONLINE_BIZ_DOWNLOAD_RESUME=no
MODULE_SHAREONLINE_BIZ_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

# Output an shareonline.biz file download URL
# $1: cookie file
# $2: shareonline.biz url
# stdout: real file download link
shareonline_biz_download() {
    local -r COOKIE_FILE=$1
    local URL=$(echo "$2" | replace '//share-online' '//www.share-online')
    local REAL_URL UPLOAD_ID TEMP FREE_URL PAGE BASE64LINK FILE_URL

    # Deal with redirs (/download.php?ID => /dl/ID/)
    REAL_URL=$(curl -I "$URL" | grep_http_header_location_quiet) || return
    if test "$REAL_URL"; then
       URL=$REAL_URL
    fi

    # Extract link id
    TEMP=$(echo $URL | parse . '/dl/\(.*\)$') || return
    UPLOAD_ID=$(uppercase "$TEMP")
    log_debug "upload_id: '$UPLOAD_ID'"

    # Get data from shareonline API
    TEMP=$(curl -d "links=$UPLOAD_ID" \
        'http://api.share-online.biz/linkcheck.php?md5=1') || return
    log_debug "API response: $TEMP"

    local API_UPLOAD_ID FILE_STATUS FILENAME API_SIZE API_MD5
    IFS=";" read API_UPLOAD_ID FILE_STATUS FILENAME API_SIZE API_MD5 <<< "$TEMP"

    log_debug "upload_id: $API_UPLOAD_ID"
    log_debug "file status: $FILE_STATUS"
    log_debug "filename: $FILENAME"
    log_debug "API size: $API_SIZE"
    log_debug "API md5 hash: $API_MD5"

    # The requested file isn't available anymore!
    if [ "$FILE_STATUS" != 'OK' ]; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Load Main page (set website language to english is not necessary)
    # PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" $URL) || return

    # Load second page
    FREE_URL="$URL/free/"
    PAGE=$(curl -b "$COOKIE_FILE" -d 'dl_free=1' "$FREE_URL" ) || return

    # Handle server response
    if match '/free/' "$PAGE"; then
        log_debug "free slot available"
    elif match 'failure/\(full\|threads\|server\)' "$PAGE"; then
        log_debug "no free user download possible for you at the moment"
        echo 120 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'failure/\(session\|ip\|bandwith\|cookie\)' "$PAGE"; then
        log_debug "there is some kind of network error at the moment"
        return $ERR_NETWORK
    elif match 'failure/size' "$PAGE"; then
        log_debug "file to big for free user download"
        return $ERR_LINK_NEED_PERMISSIONS
    else
        log_error "unknown server status - unexpected error - site update?"
        return $ERR_FATAL
    fi

    # Second Page is reCaptcha page if there was no error
    if ! match 'var captcha = false' "$PAGE"; then
        log_error "No captcha requested? Please report this issue"
        return $ERR_FATAL
    fi

    # Solve recaptcha
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6LdatrsSAAAAAHZrB70txiV5p-8Iv8BtVxlTtjKX'
    WCI=$(recaptcha_process $PUBKEY)
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    # Wait before send recaptcha data
    wait 15 || return

    BASE64LINK=$(curl -b "$COOKIE_FILE" -d 'dl_free=1' \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        "${FREE_URL}captcha/${ID}00") || return

    if [ "$BASE64LINK" = '0' ]; then
        captcha_nack $ID
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug "correct captcha"

    FILE_URL=$(echo "$BASE64LINK" | base64 --decode) || return $ERR_SYSTEM

    # Sanity check
    if [ -z "$FILE_URL" ]; then
        log_error "Emergency exit - the file url is zero - unexpected error - site update?"
        return $ERR_FATAL
    fi

    wait 32 || return

    echo "$FILE_URL"
    echo "$FILENAME"
}
