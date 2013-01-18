#!/bin/bash
#
# cloudzer.net module
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

MODULE_CLOUDZER_NET_REGEXP_URL="http://\(cloudzer\.net/file/\|clz\.to/\)"

MODULE_CLOUDZER_NET_DOWNLOAD_OPTIONS=""
MODULE_CLOUDZER_NET_DOWNLOAD_RESUME=no
MODULE_CLOUDZER_NET_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_CLOUDZER_NET_DOWNLOAD_SUCCESSIVE_INTERVAL=3600

# Output an cloudzer.net file download URL
# $1: cookie file
# $2: cloudzer.net url
# stdout: real file download link
cloudzer_net_download() {
    local -r COOKIE_FILE=$1
    local BASE_URL='http://cloudzer.net'

    # Convert URL to new style
    local URL=$(echo "$2" | replace '//clz.to' '//cloudzer.net/file')

    local FILEID PAGE RESPONSE WAITTIME FILE_NAME FILE_URL

    PAGE=$(curl -L --cookie-jar "$COOKIE_FILE" "$URL" | \
        break_html_lines_alt) || return

    if match 'class="message error"' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    FILEID=$(echo "$PAGE" | parse_attr '"auth"' 'content') || return
    WAITTIME=$(echo "$PAGE" | parse_attr '"wait"' 'content') || return
    log_debug "FileID: '$FILEID'"

    if match 'No connection to database' "$PAGE"; then
        log_debug "server error"
        echo 600 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'All of our free-download capacities are exhausted currently|The free download is currently not available' "$PAGE"; then
        log_debug "no free download slot available"
        echo 600 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 're already downloading' "$PAGE"; then
        log_debug "a download is already running"
        echo 600 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'Only Premiumusers are allowed to download files' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FILE_NAME=$(curl "${BASE_URL}/file/${FILEID}/status" | first_line) || return

    wait $((WAITTIME + 1))

    # Request captcha page
    RESPONSE=$(curl --cookie-jar "$COOKIE_FILE" \
        "${BASE_URL}/js/download.js") || return

    # Solve recaptcha
    if match 'Recaptcha.create' "$RESPONSE"; then
        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6Lcqz78SAAAAAPgsTYF3UlGf2QFQCNuPMenuyHF3'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<< "$WCI"
    else
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    # Request a download slot
    RESPONSE=$(curl -H 'X-Requested-With:XMLHttpRequest' \
        "${BASE_URL}/io/ticket/slot/$FILEID") || return

    # {"succ":true}
    if ! match_json_true 'succ' "$RESPONSE"; then
        log_error "Unexpected remote error: $RESPONSE"
        return $ERR_FATAL
    fi

    # Post captcha solution to webpage
    RESPONSE=$(curl --cookie "$COOKIE_FILE" \
        --data "recaptcha_challenge_field=$CHALLENGE" \
        --data "recaptcha_response_field=$WORD" \
        "${BASE_URL}/io/ticket/captcha/$FILEID") || return

    # Handle server (JSON) response
    if match '"captcha"' "$RESPONSE"; then
        captcha_nack $ID
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug "captcha_correct"

    if match '"type":"download"' "$RESPONSE"; then
        FILE_URL=$(echo "$RESPONSE" | parse_json url) || return
        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0

    elif match 'You have reached the max. number of possible free downloads for this hour' "$RESPONSE"; then
        log_debug "you have reached the max. number of possible free downloads for this hour"
        echo 600 # arbitary time
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match 'parallel' "$RESPONSE"; then
        log_debug "a download is already running"
        echo 600 # arbitary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}
