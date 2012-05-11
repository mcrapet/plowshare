#!/bin/bash
#
# bitshare.com module
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

MODULE_BITSHARE_REGEXP_URL="http://\(www\.\)\?bitshare\.com/"

MODULE_BITSHARE_DOWNLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free account"
MODULE_BITSHARE_DOWNLOAD_RESUME=yes
MODULE_BITSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

# Output a bitshare file download URL
# $1: cookie file
# $2: bitshare url
# stdout: real file download link
bitshare_download() {
    eval "$(process_options bitshare "$MODULE_BITSHARE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='http://bitshare.com'
    local FILE_ID POST_URL LOGIN HTML WAIT AJAXDL DATA RESPONSE
    local NEED_RECAPTCHA FILE_URL FILENAME

    FILE_ID=$(echo "$URL" | parse_quiet 'bitshare' 'bitshare\.com\/files\/\([^/]\+\)\/')
    if test -z "$FILE_ID"; then
        FILE_ID=$(echo "$URL" | parse 'bitshare' 'bitshare\.com\/?f=\(.\+\)$') || return
    fi

    log_debug "file id=$FILE_ID"
    POST_URL="$BASE_URL/files-ajax/$FILE_ID/request.html"

    # Set website language to english (language_selection=EN)
    curl -c "$COOKIEFILE" -o /dev/null "$BASE_URL/?language=EN" || return

    # Login
    if test "$AUTH_FREE"; then
        post_login "$AUTH_FREE" "$COOKIEFILE" \
            'user=$USER&password=$PASSWORD&rememberlogin=&submit=Login' \
            "$BASE_URL/login.html" > /dev/null
        LOGIN=$(parse_cookie_quiet 'login' < "$COOKIEFILE")
        if test -z "$LOGIN"; then
            return $ERR_LOGIN_FAILED
        else
            log_debug "successfully logged in"
        fi
    fi

    # Add cookie entries: last_file_downloaded, trafficcontrol
    HTML=$(curl -b "$COOKIEFILE" -c "$COOKIEFILE" "$URL") || return

    # File unavailable
    if match "<h1>Error - File not available</h1>" "$HTML"; then
        return $ERR_LINK_DEAD

    # Download limit
    elif match "You reached your hourly traffic limit\." "$HTML"; then
        WAIT=$(echo "$HTML" | parse '<span id="blocktimecounter">' \
            '<span id="blocktimecounter">\([[:digit:]]\+\) seconds\?<\/span>')
        echo $((WAIT))
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match "Sorry, you cant download more then [[:digit:]]\+ files\? at time\." "$HTML"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Note: filename is <h1> tag might be truncated
    FILENAME=$(echo "$HTML" | parse 'http:\/\/bitshare\.com\/files\/' \
        'value="http:\/\/bitshare\.com\/files\/'"$FILE_ID"'\/\(.*\)\.html"') || return

    # Add cookie entry: ads_download=1
    curl -b "$COOKIEFILE" -c "$COOKIEFILE" -o /dev/null \
        "$BASE_URL/getads.html" || return

    # Get ajaxdl id
    AJAXDL=$(echo "$HTML" | parse 'var ajaxdl = ' \
        'var ajaxdl = "\([^"]\+\)";') || return

    # Retrieve parameters
    # Example: file:60:1
    DATA="request=generateID&ajaxid=$AJAXDL"
    RESPONSE=$(curl -b "$COOKIEFILE" --referer "$URL" --data "$DATA" \
        "$POST_URL") || return

    if match '^ERROR' "$RESPONSE"; then
        log_error "failed in retrieving parameters: $RESPONSE"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    WAIT=$(echo "$RESPONSE" | parse ':' ':\([[:digit:]]\+\):') || return
    NEED_RECAPTCHA=$(echo "$RESPONSE" | parse ':' ':\([^:]\+\)$') || return

    if [ "$NEED_RECAPTCHA" -eq 1 ]; then
        log_debug "need recaptcha"
    else
        log_debug "no recaptcha needed"
    fi

    wait $WAIT seconds || return

    # ReCaptcha
    if [ "$NEED_RECAPTCHA" -eq 1 ]; then
        local PUBKEY WCI CHALLENGE WORD ID RECAPTCHA_RESULT
        PUBKEY='6LdtjrwSAAAAACepq37DE6GDMp1TxvdbW5ui0rdE'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        DATA="request=validateCaptcha&ajaxid=$AJAXDL&recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD"
        RECAPTCHA_RESULT=$(curl -b "$COOKIEFILE" --referer "$URL" --data "$DATA" \
            "$POST_URL") || return

        if ! match '^SUCCESS:\?' "$RECAPTCHA_RESULT"; then
            log_error 'Wrong captcha'
            captcha_nack $ID
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug "correct captcha"
    fi

    # Get file url
    DATA="request=getDownloadURL&ajaxid=$AJAXDL"
    RESPONSE=$(curl -b "$COOKIEFILE" --referer "$URL" --data "$DATA" \
        "$POST_URL") || return

    if match 'ERROR#' "$RESPONSE"; then
        log_error "getting file url fail: $RESPONSE"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FILE_URL=$(echo "$RESPONSE" | parse 'SUCCESS#' '^SUCCESS#\(.*\)$')

    echo "$FILE_URL"
    echo "$FILENAME"
}
