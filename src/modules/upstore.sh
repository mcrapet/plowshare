#!/bin/bash
#
# upstore module
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

MODULE_UPSTORE_REGEXP_URL="https\?://\(www\.\)\?upsto\(\.re\|re\.net\)/"

MODULE_UPSTORE_DOWNLOAD_OPTIONS=""
MODULE_UPSTORE_DOWNLOAD_RESUME=no
MODULE_UPSTORE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_UPSTORE_DOWNLOAD_SUCCESSIVE_INTERVAL=900


# Output a file URL to download from Upsto.re
# $1: cookie file (not used here)
# $2: upstore url
# stdout: real file download link
#         file name
upstore_download() {
    local -r URL=$2
    local -r BASE_URL='http://upstore.net'
    local PAGE HASH ERR WAIT

    # extract file ID from URL
    #  http://upstore.net/xyz
    #  http://upsto.re/xyz
    HASH=$(echo "$URL" | parse '' 'upsto[^/]\+/\([[:alnum:]]\+\)') || return
    log_debug "File ID: '$HASH'"

    PAGE=$(curl -b 'lang=en' "$BASE_URL/$HASH") || return
    ERR=$(echo "$PAGE" | parse_tag_quiet 'span class="error"' span) || return

    if [ -n "$ERR" ]; then
        [ "$ERR" = 'File not found' ] && return $ERR_LINK_DEAD
        [ -n "$CHECK_LINK" ] && return 0

        #File size is larger than 1 GB. Unfortunately, it can be downloaded only with premium
        if [[ "$ERR" = 'File size is larger than'* ]]; then
                return $ERR_LINK_NEED_PERMISSIONS
        fi

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    [ -n "$CHECK_LINK" ] && return 0

    PAGE=$(curl -b 'lang=en' -d "hash=$HASH" \
        -d 'free=Slow download' "$BASE_URL/$HASH") || return

    # Error message is inside <span> or <h2> tag
    ERR=$(echo "$PAGE" | parse_quiet 'class="error"' '>\([^<]\+\)</') || return

    if [ -n "$ERR" ]; then
        case "$ERR" in
            # Sorry, but server with file is overloaded
            # Server for free downloads is overloaded
            [Ss]erver*overloaded*)
                log_error 'No free download slots available'
                echo 120 # wait some arbitrary time
                return $ERR_LINK_TEMP_UNAVAILABLE
                ;;

            *'only for Premium users')
                return $ERR_LINK_NEED_PERMISSIONS
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

    PAGE=$(curl -b 'lang=en' -d "recaptcha_response_field=$WORD"  \
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
            'Sorry, but server with file is overloaded'*)
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
        esac

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    # extract + output download link + file name
    echo "$PAGE" | parse_attr '<b>Download file</b>' 'href' || return
    echo "$PAGE" | parse_tag '^[[:space:]]*Download file <b>' 'b' | html_to_utf8 || return
}
