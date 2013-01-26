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
MODULE_SHAREONLINE_BIZ_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_SHAREONLINE_BIZ_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"
MODULE_SHAREONLINE_BIZ_UPLOAD_REMOTE_SUPPORT=no

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

    local CAP_ID URL_ID
    CAP_ID=$(echo "$PAGE" | parse 'var[[:space:]]\+dl=' \
        '[[:space:]]dl="\([^"]*\)') || return
    CAP_ID=$(base64 -d <<< "$CAP_ID")
    URL_ID=$(echo "$PAGE" | parse '///' '///\([[:digit:]]\+\)') || return
    log_debug "captcha: '$CAP_ID'"
    log_debug "url id: $URL_ID"

    # Solve recaptcha
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6LdatrsSAAAAAHZrB70txiV5p-8Iv8BtVxlTtjKX'
    WCI=$(recaptcha_process $PUBKEY)
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    # Wait before send recaptcha data
    wait 15 || return

    BASE64LINK=$(curl -b "$COOKIE_FILE" -d 'dl_free=1' \
        -d "captcha=${CAP_ID:5}" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        "${FREE_URL}captcha/$URL_ID") || return

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

# Upload a file to Share-Online.biz
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: shareonline download link
shareonline_biz_upload() {
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r REQUEST_URL='http://www.share-online.biz/upv3_session.php'
    local DATA USER PASSWORD ERR UP_URL SESSION_ID SIZE SIZE_SRV LINK MD5

    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS

    # We use the public upload API (http://www.share-online.biz/uploadapi/)

    split_auth "$AUTH_FREE" USER PASSWORD || return

    # Create upload session
    DATA=$(curl -F "username=$USER" -F "password=$PASSWORD" "$REQUEST_URL") || return

    if match '<title>502 Bad Gateway</title>' "$DATA"; then
        log_error 'Remote server error, maybe due to overload.'
        echo 120 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    ERR=$(echo "$DATA" | parse_quiet '^\*\*\* EXCEPTION \(.\+\) -')
    if [ -n "$ERR" ]; then
        if [ "$ERR" = 'username or password invalid' ]; then
            return $ERR_LOGIN_FAILED
        fi

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    # EN29W3AMYGX0;dlw159-2.share-online.biz/upload
    IFS=';' read SESSION_ID UP_URL <<< "$DATA"

    match_remote_url $UP_URL || UP_URL="http://$UP_URL"
    SIZE=$(get_filesize "$FILE") || return

    DATA=$(curl -F "username=$USER" -F "password=$PASSWORD" \
        -F "upload_session=$SESSION_ID" -F 'chunk_no=1' -F 'chunk_number=1' \
        -F "filesize=$SIZE" -F "fn=@$FILE;filename=$DEST_FILE" -F 'finalize=1' \
        "$UP_URL") || return

    ERR=$(echo "$DATA" | parse_quiet '^\*\*\* EXCEPTION \(.\+\) -')

    if [ -n "$ERR" ]; then
        if [ "$ERR" = 'session creation/reuse failed -' ]; then
            log_error 'Server reports invalid session'
            return $ERR_FATAL
        fi

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    # http://www.share-online.biz/dl/8XDBW3AM57;128;656957fb0a59502fc47c7c01a814d21f
    IFS=";" read LINK SIZE_SRV MD5 <<< "$DATA"

    log_debug "File size on server: $SIZE_SRV"
    log_debug "MD5 hash: $MD5"

    if [ $SIZE -ne $SIZE_SRV ]; then
        log_error "Server reports wrong filesize: $SIZE_SRV (local: $SIZE)"
    fi

    echo "$LINK"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: shareonline_biz url
# $3: requested capability list
# stdout: 1 capability per line
shareonline_biz_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE TEMP DLID REQ_OUT

    PAGE=$(curl -L "$URL") || return
    DLID=$(echo "$PAGE" | parse_quiet '[[:space:]/]dl/' 'dl/\(..........\)[</]')

    test "$DLID" || return $ERR_LINK_DEAD

    # Official API Documentation
    # http://www.share-online.biz/linkcheckapi/
    TEMP=$(curl -d "links=$DLID" \
        'http://api.share-online.biz/linkcheck.php?md5=1') || return

    log_debug "API response: '$TEMP'"

    local ID FILE_STATUS FILE_NAME SIZE HASH
    IFS=";" read ID FILE_STATUS FILE_NAME SIZE HASH <<< "$TEMP"

    # The requested file isn't available anymore!
    if [ "$FILE_STATUS" != 'OK' ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        test "$FILE_NAME" && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *h* ]]; then
        test "$HASH" && echo "$HASH" && REQ_OUT="${REQ_OUT}h"
    fi

    if [[ $REQ_IN = *s* ]]; then
        test "$SIZE" && echo "$SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
