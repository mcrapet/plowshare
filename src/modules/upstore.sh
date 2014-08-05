# Plowshare upstore module
# Copyright (c) 2013-2014 Plowshare team
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

MODULE_UPSTORE_REGEXP_URL='https\?://\(www\.\)\?upsto\(\.re\|re\.net\)/'

MODULE_UPSTORE_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account"
MODULE_UPSTORE_DOWNLOAD_RESUME=no
MODULE_UPSTORE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_UPSTORE_DOWNLOAD_SUCCESSIVE_INTERVAL=900

MODULE_UPSTORE_UPLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account
SHORT_LINK,,short-link,,Produce short link like http://upsto.re/XXXXXX"
MODULE_UPSTORE_UPLOAD_UPLOAD_REMOTE_SUPPORT=no

MODULE_UPSTORE_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
upstore_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE STATUS NAME

    LOGIN_DATA='email=$USER&password=$PASSWORD&send=Login'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/account/login/" -b 'lang=en' --location) || return

    STATUS=$(parse_cookie_quiet 'usid' < "$COOKIE_FILE")
    [ -n "$STATUS" ] || return $ERR_LOGIN_FAILED

    # Determine account type and user name
    NAME=$(parse '"/account/"' '^[[:space:]]*\(.*\)$' 1 <<< "$PAGE")

    if match '="/premium/">renew</a>' "$PAGE"; then
        echo 'premium'
    else
        echo 'free'
    fi

    log_debug "Successfully logged in as member '$NAME'"
}

# Switch language to english
# $1: cookie file
# $2: base URL
upstore_switch_lang() {
    curl -c "$1" -o /dev/null "$2/?lang=en" || return
}

# Output a file URL to download from Upsto.re
# $1: cookie file
# $2: upstore url
# stdout: real file download link
#         file name
upstore_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://upstore.net'
    local PAGE HASH ERR WAIT JSON

    # extract file ID from URL
    #  http://upstore.net/xyz
    #  http://upsto.re/xyz
    HASH=$(echo "$URL" | parse '' 'upsto[^/]\+/\([[:alnum:]]\+\)') || return
    log_debug "File ID: '$HASH'"

    upstore_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    if [ -n "$AUTH" ]; then
        ACC=$(upstore_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' "$BASE_URL/$HASH") || return
    ERR=$(echo "$PAGE" | parse_tag_quiet 'span class="error"' span) || return

    if [ -n "$ERR" ]; then
        [ "$ERR" = 'File not found' ] && return $ERR_LINK_DEAD

        # File size is larger than 1 GB. Unfortunately, it can be downloaded only with premium
        if [[ "$ERR" = 'File size is larger than'* ]]; then
                return $ERR_LINK_NEED_PERMISSIONS
        fi

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    if [ -n "$AUTH" -a "$ACC" = 'premium' ]; then
        JSON=$(curl -b "$COOKIE_FILE" -b 'lang=en' --referer "$URL" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d "hash=$HASH" \
            -d 'antispam=' \
            -d 'js=1' "$BASE_URL/load/premium/") || return

        parse_json 'ok' <<< "$JSON" || return
        return 0
    fi

    PAGE=$(curl -b 'lang=en' -d "hash=$HASH" \
        -d 'free=Slow download' "$BASE_URL/$HASH") || return

    # Error message is inside <span> or <h2> tag
    ERR=$(echo "$PAGE" | parse_quiet 'class="error"' '>\([^<]\+\)</') || return

    if [ -n "$ERR" ]; then
        case "$ERR" in
            # Sorry, but server with file is overloaded
            # Server for free downloads is overloaded
            *[Ss]erver*overloaded*)
                log_error 'No free download slots available'
                echo 120 # wait some arbitrary time
                return $ERR_LINK_TEMP_UNAVAILABLE
                ;;

            *'only for Premium users')
                return $ERR_LINK_NEED_PERMISSIONS
                ;;
        esac

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    WAIT=$(echo "$PAGE" | parse 'Please wait %s before downloading' \
        '^var sec = \([[:digit:]]\+\),') || return
    wait $((WAIT + 1)) || return

    # Solve recaptcha
    local PUBKEY WCI CHALLENGE WORD CONTROL ID
    PUBKEY='6LeqftkSAAAAAHl19qD7wPAVglFYWhZPTjno3wFb'
    WCI=$(recaptcha_process $PUBKEY)
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' -d "recaptcha_response_field=$WORD" \
        -d "recaptcha_challenge_field=$CHALLENGE" -d "hash=$HASH" \
        -d 'free=Get download link' "$BASE_URL/$HASH") || return
    ERR=$(echo "$PAGE" | parse_tag_quiet 'span class="error"' span) || return

    if [ -n "$ERR" ]; then
        if [ "$ERR" = 'Wrong captcha protection code' ]; then
            log_error 'Wrong captcha'
            captcha_nack $ID
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID

        case "$ERR" in
            *[Ss]erver*overloaded*)
                log_error 'No free download slots available'
                echo 120 # wait some arbitrary time
                return $ERR_LINK_TEMP_UNAVAILABLE
                ;;

            # Sorry, you have reached a download limit for today (3 files). Please wait for tomorrow or...
            *'you have reached a download limit for today'*)
                # We'll take it literally and wait till the next day
                # Note: Consider the time zone of their server (+0:00)
                local HOUR MIN TIME

                # Get current UTC time, prevent leading zeros
                TIME=$(date -u +'%k:%M') || return
                HOUR=${TIME%:*}
                MIN=${TIME#*:}

                log_error 'Daily limit reached.'
                echo $(( ((23 - HOUR) * 60 + (61 - ${MIN#0}) ) * 60 ))
                return $ERR_LINK_TEMP_UNAVAILABLE
                ;;

            # Sorry, we have found that you or someone else have already downloaded another file recently from your IP (1.1.1.1). You should wait 13 minutes before downloading next file
            *'you or someone else have already downloaded'*)
                local WAIT
                WAIT=$(echo "$ERR" | parse '' \
                    'wait \([[:digit:]]\+\) minute') || return
                log_error 'Forced delay between downloads.'
                echo $(( WAIT * 60 + 1 ))
                return $ERR_LINK_TEMP_UNAVAILABLE
                ;;

            # Sorry, we have found that you have already downloaded several files recently.
            *'downloaded several files recently'*)
                log_error 'Forced delay between downloads.'
                echo 3600 # wait some arbitrary time
                return $ERR_LINK_TEMP_UNAVAILABLE
                ;;
        esac

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    captcha_ack $ID

    # extract + output download link + file name
    echo "$PAGE" | parse_attr '<b>Download file</b>' 'href' || return
    echo "$PAGE" | parse_tag '^[[:space:]]*Download file <b>' 'b' | html_to_utf8 || return
}

# Upload a file to Upstore.net
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
upstore_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://upstore.net'
    local PAGE JSON UP_URL FILE_SIZE MAX_SIZE HASH OPT_USER

    upstore_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    if [ -n "$AUTH" ]; then
        upstore_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" >/dev/null || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return
    UP_URL=$(echo "$PAGE" | parse 'script' "'\([^']\+\)',") || return
    MAX_SIZE=$(echo "$PAGE" | parse 'sizeLimit' \
        '[[:blank:]]\([[:digit:]]\+\),') || return

    log_debug "URL: '$UP_URL'"
    log_debug "Max size: '$MAX_SIZE'"

    # Check file size
    SIZE=$(get_filesize "$FILE") || return
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$AUTH" ]; then
        local USER_ID

        USER_ID=$(echo "$PAGE" | parse 'usid' ":[[:blank:]]'\([^']\+\)'") || return
        log_debug "User ID: '$USER_ID'"
        OPT_USER="-F usid=$USER_ID"
    fi

    # Note: Uses SWF variant of Uploadify v2.1.4 (jquery.uploadify)
    JSON=$(curl_with_log --user-agent 'Shockwave Flash' -b "$COOKIE_FILE"  \
        -F "Filename=$DEST_FILE" \
        -F 'folder=/'            \
        $OPT_USER                \
        -F 'fileext=*.*'         \
        -F "file=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        -F 'Upload=Submit Query' \
        "$UP_URL") || return

    HASH=$(echo "$JSON" | parse_json 'hash') || return

    if [ -n "$SHORT_LINK" ]; then
        echo "http://upsto.re/$HASH"
    else
        echo "$BASE_URL/$HASH"
    fi

}

# Probe a download URL
# $1: cookie file (unused here)
# $2: Upstore url
# $3: requested capability list
# stdout: 1 capability per line
upstore_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl --location -b 'lang=en' "$URL") || return

    match 'File not found' "$PAGE" && return $ERR_LINK_DEAD
    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$PAGE" | parse '<div.*Download file' '>\([^<]\+\)<' 1 | \
            html_to_utf8 && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse '<div.*Download file' \
            '^[[:blank:]]*\([[:digit:]]\+\(.[[:digit:]]\+\)\?[[:space:]][KMG]\?B\)' 3) &&
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
