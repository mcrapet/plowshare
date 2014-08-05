# Plowshare fileover.net module
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

MODULE_FILEOVER_REGEXP_URL='https\?://\(www\.\)\?fileover\.net/'

MODULE_FILEOVER_DOWNLOAD_OPTIONS=""
MODULE_FILEOVER_DOWNLOAD_RESUME=no
MODULE_FILEOVER_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FILEOVER_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FILEOVER_PROBE_OPTIONS=""

# Output a fileover.net file download URL
# $1: cookie file (unused here)
# $2: fileover.net url
# stdout: real file download link
fileover_download() {
    local COOKIE_FILE=$1
    local URL=$2
    local BASE_URL='http://fileover.net'
    local PAGE FILE_ID FILE_NAME WAIT JSON HASH FILE_URL

    PAGE=$(curl -L "$URL") || return

    # The following file is unavailable
    # The file was completely removed from our servers.</p>
    if match 'file is unavailable\|file was completely removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_ID=$(parse '/ax/time' "'[[:space:]]*+[[:space:]]*\([[:digit:]]\+\)" <<< "$PAGE") || return
    log_debug "File ID: '$FILE_ID'"

    FILE_NAME=$(parse_tag '<h2[[:space:]]' h2 <<< "$PAGE")

    # <h3>You have to wait: 14 minutes 57 seconds.
    if matchi 'You have to wait' "$PAGE"; then
        local MINS SECS
        MINS=$(parse_quiet 'u have to wait' ':[[:space:]]*\([[:digit:]]\+\) minute' <<< "$PAGE")
        SECS=$(parse_quiet 'u have to wait' '[[:space:]]\+\([[:digit:]]\+\) second' <<< "$PAGE")

        echo $(( MINS * 60 + SECS ))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # <h3 class="waitline">Wait Time: <span class="wseconds">20</span>s</h3>
    WAIT=$(parse_tag '^[[:space:]]\+<h3.*waitline.>' span <<< "$PAGE") || return

    # {"hash":"df65ff1c76bdacbe92816971651b91cd"}
    JSON=$(curl -H 'X-Requested-With: XMLHttpRequest' \
        --referer "$URL" "$BASE_URL/ax/timereq.flo?$FILE_ID") || return

    HASH=$(parse_json hash <<< "$JSON") || return
    log_debug "Hash: '$HASH'"

    wait "$WAIT" || return

    PAGE=$(curl "$BASE_URL/ax/timepoll.flo?file=$FILE_ID&hash=$HASH") || return

    # reCaptcha part
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6LfT08MSAAAAAP7dyRaVw9N-ZaMy0SK6Nw1chr7i'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    PAGE=$(curl -d "file=$FILE_ID" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" -d "hash=$HASH" \
        "$BASE_URL/ax/timepoll.flo") || return

    if match '/recaptcha/' "$PAGE"; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    # Click here to Download
    FILE_URL=$(parse_attr 'Download' href <<< "$PAGE") || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: fileover url
# $3: requested capability list
# stdout: 1 capability per line
fileover_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT

    PAGE=$(curl -L "$URL") || return

    # The following file is unavailable
    # The file was completely removed from our servers.</p>
    if match 'file is unavailable\|file was completely removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag '<h2[[:space:]]' h2 <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    echo $REQ_OUT
}
