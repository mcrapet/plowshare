#!/bin/bash
#
# shareonline.biz module
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

MODULE_SHAREONLINE_BIZ_REGEXP_URL="http://\(\www\.\)\?\(share\-online\.biz\|egoshare\.com\)/\(download\.php?id\=\|dl/\)\(\w\)"

MODULE_SHAREONLINE_BIZ_DOWNLOAD_OPTIONS=""
MODULE_SHAREONLINE_BIZ_DOWNLOAD_RESUME=no
MODULE_SHAREONLINE_BIZ_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_SHAREONLINE_BIZ_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_SHAREONLINE_BIZ_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"
MODULE_SHAREONLINE_BIZ_UPLOAD_REMOTE_SUPPORT=no

# Output an shareonline.biz file download URL
# $1: cookie file (unused here)
# $2: shareonline.biz url
# stdout: real file download link
shareonline_biz_download() {
    local -r BASE_URL='http://www.share-online.biz'
    local URL FILE_ID PAGE REDIR BASE64LINK FILE_URL
    local API_FILE_ID FILE_STATUS FILE_NAME SIZE
    local CAP_ID URL_ID WAIT

    if ! check_exec 'base64'; then
        log_error "'base64' is required but was not found in path."
        return $ERR_FATAL
    fi

    # Extract file ID from all possible URL formats
    #  http://www.share-online.biz/download.php?id=xyz
    #  http://share-online.biz/download.php?id=xyz
    FILE_ID=$(echo $2 | parse_quiet . 'id=\([[:alnum:]]\+\)$')

    #  http://www.share-online.biz/dl/xyz
    #  http://share-online.biz/dl/xyz
    if [ -z "$FILE_ID" ]; then
        FILE_ID=$(echo $2 | parse_quiet . '/dl/\([[:alnum:]]\+\)$')
    fi

    if [ -z "$FILE_ID" ]; then
        log_error 'Could not get file ID. Site updated?'
        return $ERR_FATAL
    fi

    FILE_ID=$(uppercase "$FILE_ID")
	URL="$BASE_URL/dl/$FILE_ID/free/"
    log_debug "File ID: '$FILE_ID'"

    # Get data from shareonline API
    # Note: API requires ID to be uppercase
    PAGE=$(curl -d "links=$FILE_ID" \
        "${BASE_URL/www/api}/linkcheck.php") || return
    log_debug "API response: $PAGE"

    IFS=";" read API_FILE_ID FILE_STATUS FILE_NAME SIZE <<< "$PAGE"

    log_debug "File ID: $API_FILE_ID"
    log_debug "File status: $FILE_STATUS"
    log_debug "Filename: $FILE_NAME"
    log_debug "File size: $SIZE"

    # The requested file isn't available anymore!
    [ "$FILE_STATUS" = 'OK' ] || return $ERR_LINK_DEAD
    [ -n "$CHECK_LINK" ] && return 0

    # Load second page
    PAGE=$(curl --include -d 'dl_free=1' -d 'choice=free' "$URL" ) || return

    # Handle errors/redirects
    REDIR=$(echo "$PAGE" | grep_http_header_location_quiet)

    if [ -n "$REDIR" ]; then
        local ERR=$(echo "$REDIR" | parse_quiet . 'failure/\([^/]\+\)')

        case $ERR in
            ipfree)
                log_error 'No parallel download allowed.'
                ;;
            full)
                log_error 'No free download possible at the moment.'
                ;;
            session|bandwidth|overload|cookie|expired|invalid|precheck|proxy|threads|server|chunks)
                log_error 'Server issues.'
                ;;
            freelimit)
                return $ERR_LINK_NEED_PERMISSIONS
                ;;
            size)
                return $ERR_SIZE_LIMIT_EXCEEDED
                ;;
            *)
                # Note: This also matches when "$ERR" is empty.
                log_error "Unexpected server response (REDIR = '$REDIR'). Site updated?"
                return $ERR_FATAL
                ;;
        esac

        echo 120 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Second Page is reCaptcha page if there was no error
    if ! match 'var captcha = false' "$PAGE"; then
        log_error 'No captcha requested? Please report this issue'
        return $ERR_FATAL
    fi

    CAP_ID=$(echo "$PAGE" | parse 'var[[:space:]]\+dl=' \
        '[[:space:]]dl="\([^"]*\)') || return
    CAP_ID=$(base64 -d <<< "$CAP_ID")
    URL_ID=$(echo "$PAGE" | parse '///' '///\([[:digit:]]\+\)') || return
    log_debug "Captcha: '$CAP_ID'"
    log_debug "URL ID: $URL_ID"

    # Solve recaptcha
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6LdatrsSAAAAAHZrB70txiV5p-8Iv8BtVxlTtjKX'
    WCI=$(recaptcha_process $PUBKEY)
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    # Wait before send recaptcha data (and then again before actual download)
    # 'var wait=30; [...] <current time> + wait/2'
    WAIT=$(echo "$PAGE" | parse 'var wait' 'wait=\([[:digit:]]\+\)') || return
    wait $(( ($WAIT / 2) + 1 )) || return

    BASE64LINK=$(curl -b "$COOKIE_FILE" -d 'dl_free=1' \
        -d "captcha=${CAP_ID:5}" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        "${URL}captcha/$URL_ID") || return

    if [ "$BASE64LINK" = '0' ]; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    FILE_URL=$(echo "$BASE64LINK" | base64 --decode) || return $ERR_SYSTEM

    # Sanity check
    if [ -z "$FILE_URL" ]; then
        log_error 'File URL not found. Site updated?'
        return $ERR_FATAL
    fi

    wait $(( $WAIT + 1 )) || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
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
    DLID=$(echo "$PAGE" | parse_quiet '[[:space:]/]dl/' 'dl/\([[:alnum:]]\+\)[</]')

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
