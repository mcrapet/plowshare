# Plowshare filer.net module
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

MODULE_FILER_NET_REGEXP_URL='http://\(www\.\)\?filer\.net/'

MODULE_FILER_NET_DOWNLOAD_OPTIONS=""
MODULE_FILER_NET_DOWNLOAD_RESUME=yes
MODULE_FILER_NET_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FILER_NET_DOWNLOAD_SUCCESSIVE_INTERVAL=""

MODULE_FILER_NET_LIST_OPTIONS=""
MODULE_FILER_NET_LIST_HAS_SUBFOLDERS=no

MODULE_FILER_NET_PROBE_OPTIONS=""

# Switch language to english
# $1: cookie file
# $2: base URL
filer_net_switch_lang() {
    # Note: Language is associated with session, faking the cookie is not enough
    curl -c "$1" -o /dev/null "$2/locale/en" || return
}

# Output an filer.net file download URL
# $1: cookie file
# $2: filer.net url
# stdout: real file download link
filer_net_download() {
    local -r COOKIE_FILE=$1
    local URL=$2
    local -r BASE_URL='http://filer.net'

    local FILE_ID PAGE TOKEN WAIT

    # Check if link is a shared folder
    if match '/folder/' "$URL"; then
        log_error 'This is a shared folder - use plowlist'
        return $ERR_FATAL
    fi

    FILE_ID=$(parse_quiet . 'get/\([[:alnum:]]\+\)$' <<< "$URL")
    log_debug "File ID: '$FILE_ID'"

    if [ -z "$FILE_ID" ]; then
        log_error 'Could not get file ID. Site updated?'
        return $ERR_FATAL
    fi

    URL="$BASE_URL/get/$FILE_ID"

    local API_RESPONSE FILE_STATUS FILE_NAME

    API_RESPONSE=$(curl -L \
        "http://api.filer.net/status/${FILE_ID}.json") || return
    log_debug "json: '$API_RESPONSE'"

    FILE_STATUS=$(parse_json 'status' <<< "$API_RESPONSE")

    # The requested file isn't available anymore!
    if [ "$FILE_STATUS" != 'ok' ]; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(parse_json 'name' <<< "$API_RESPONSE")

    filer_net_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    # Load first page
    PAGE=$(curl -b "$COOKIE_FILE" -L "$URL" ) || return

    # Error handling
    # - another download is active from this ip
    if match 'Maximale Verbindungen erreicht' "$PAGE"; then
        log_error 'No parallel download allowed.'
        echo 120 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE

    # - free download limit reached
    elif match 'Free Download Limit erreicht' "$PAGE"; then
        log_error 'Free Download Limit reached'
        WAIT=$(parse_tag 'id=.time.>' span <<< "$PAGE")
        echo $((WAIT))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    TOKEN=$(echo "$PAGE" | parse 'token' 'value="\([[:alnum:]]\+\)') || return
    log_debug "token: '$TOKEN'"
    WAIT=$(parse_tag 'id=.time.>' em <<< "$PAGE")
    wait $(( $WAIT + 1 )) || return

    # Push download button
    PAGE=$(curl -b "$COOKIE_FILE" -d "token=$TOKEN" "$URL") || return

    # Second page is reCaptcha page if there was no error
    if ! match 'recaptcha_challenge_field' "$PAGE"; then
        log_error 'No captcha requested? Please report this issue'
        return $ERR_FATAL
    fi

    local PUBKEY WCI WORD CHALLENGE ID FILE_URL

    PUBKEY='6LcFctISAAAAAAgaeHgyqhNecGJJRnxV1m_vAz3V'
    WCI=$(recaptcha_process $PUBKEY)
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    # Problem: this curl command download the file immediately
    # submit recaptcha data
    PAGE=$(curl --include -b "$COOKIE_FILE" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        -d "hash=$FILE_ID" \
        "${BASE_URL}/get/$FILE_ID" ) || return

    FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

    if [ -z "$FILE_URL" ]; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'correct captcha'

    local TRY
    for TRY in 1 2; do
        # $(basename_url "$FILE_URL") is different from $BASE_URL
        if match_remote_url "$FILE_URL"; then
            echo "$FILE_URL"
            echo "$FILE_NAME"
            return 0
        fi

        PAGE=$(curl --include -b "$COOKIE_FILE" "$BASE_URL$FILE_URL") || return
        FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")
    done

    log_error 'Remote server error, too many redirections'
    return $ERR_FATAL
}

# List a filer.net shared file folder URL
# $1: filer.net folder url (http://filer.net/folder/...)
# $2: recurse subfolders (ignored here)
# stdout: list of links
filer_net_list() {
    local -r URL=$1
    local PAGE LINKS NAMES

    # check if link is really a shared folder
    if ! match '/folder/' "$URL"; then
        log_error 'This is not a shared folder'
        return $ERR_FATAL
    fi

    # Load first PAGE
    PAGE=$(curl -L "$URL" ) || return

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet '/get/.*<img[[:space:]]' href)
    test "$LINKS" || return $ERR_LINK_DEAD

    NAMES=$(echo "$PAGE" | parse_all_quiet '/get/.*<img[[:space:]]' '>\([^<]\+\)</a>' -2)

    list_submit "$LINKS" "$NAMES" 'http://filer.net'
}

# Probe a download URL
# Official API documentation: http://filer.net/api
# $1: cookie file (unused here)
# $2: filer.net url
# $3: requested capability list
# stdout: 1 capability per line
filer_net_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local FILE_ID REQ_OUT API_RESPONSE FILE_STATUS

    FILE_ID=$(parse_quiet . 'get/\([[:alnum:]]\+\)$' <<< "$URL")
    log_debug "File ID: '$FILE_ID'"

    if [ -z "$FILE_ID" ]; then
        log_error 'Could not get file ID. Site updated?'
        return $ERR_FATAL
    fi

    API_RESPONSE=$(curl -L \
        "http://api.filer.net/status/${FILE_ID}.json") || return
    log_debug "json: '$API_RESPONSE'"

    FILE_STATUS=$(parse_json 'status' <<< "$API_RESPONSE")

    # The requested file isn't available anymore!
    if [ "$FILE_STATUS" != 'ok' ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_json 'name' <<< "$API_RESPONSE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        parse_json 'size' <<< "$API_RESPONSE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        # parse_json 'hash' <<< "$API_RESPONSE" && REQ_OUT="${REQ_OUT}h"
        echo "$FILE_ID" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}
