# Plowshare nakido.com module
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

MODULE_NAKIDO_REGEXP_URL='https\?://\(www\.\)\?nakido\.com/'

MODULE_NAKIDO_DOWNLOAD_OPTIONS=""
MODULE_NAKIDO_DOWNLOAD_RESUME=no
MODULE_NAKIDO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_NAKIDO_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_NAKIDO_PROBE_OPTIONS=""

# Static function. Extract file key from download link.
# $1: Nakido download URL
# - http://www.nakido.com/HHHH...
# stdout: file key
nakido_extract_key() {
    local ID=$(parse_quiet . '/\([[:xdigit:]]\{40\}\)$' <<< "$1")
    if [ -z "$ID" ]; then
        log_error 'Cannot extract file key, check your link url'
        return $ERR_FATAL
    else
        log_debug "File key: '$ID'"
        echo "$ID"
    fi
}

# Output a nakido file download URL
# $1: cookie file
# $2: nakido url
# stdout: real file download link
nakido_download() {
    local -r COOKIE_FILE=$1
    local URL=$2
    local -r BASE_URL='http://www.nakido.com'
    local PAGE FILE_KEY FILE_NAME FILE_NAME2 FILE_URL HASH I

    FILE_KEY=$(nakido_extract_key "$URL") || return

    # Get 'session' cookie
    PAGE=$(curl -c "$COOKIE_FILE" -b 'lang=en-us' -b "$COOKIE_FILE" \
        --referer "$BASE_URL/$FILE_KEY" \
        "$BASE_URL/dl?filekey=$FILE_KEY&action=add") || return

    # URL encoded (%xx)
    FILE_NAME=$(parse 'Nakido\.downloads\[' \
        "^Nakido\.downloads\['${FILE_KEY}f'\]='\([^']\+\)" <<< "$PAGE") || return
    FILE_NAME2=$(parse_tag 'class=.link.' a <<< "$PAGE")

    HASH=$(parse 'Nakido\.downloads\[' \
        "\]='\([[:xdigit:]]\+\)';[[:cntrl:]]$" <<< "$PAGE") || return
    log_debug "File hash: '$HASH'"

    for I in 2 3 4; do
        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en-us' \
            --referer "$BASE_URL/dl?filekey=$FILE_KEY&action=add" \
            "$BASE_URL/dl/ticket?f=$FILE_KEY&o=$HASH") || return

        # Returns:
        # E6AC634B1946F301DD17617E51067985DC1866BA#3903
        if match "$FILE_KEY#0$" "$PAGE"; then
            log_debug 'Wait complete!'
            break
        elif match "$FILE_KEY#" "$PAGE"; then
            local WAIT=${PAGE#*#}
            wait $((WAIT + 1)) || return
        else
            log_error "Unexpected response: $PAGE"
            return $ERR_FATAL
        fi
    done

    PAGE=$(curl -I -b "$COOKIE_FILE" -b 'lang=en-us' \
        "$BASE_URL/$FILE_KEY/$FILE_NAME") || return
    FILE_URL=$(grep_http_header_location <<< "$PAGE") || return

    echo "$FILE_URL"
    echo "$FILE_NAME2"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: nakido url
# $3: requested capability list
# stdout: 1 capability per line
nakido_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT

    PAGE=$(curl -L -b 'lang=en-us' "$URL") || return

    # <div id="notification">The page you have requested is not exists
    if match ' page you have requested is not exist' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag h1 <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    echo $REQ_OUT
}
