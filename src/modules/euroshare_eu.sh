#!/bin/bash
#
# euroshare.eu module
# Copyright (c) 2011 halfman <Pulpan3@gmail.com>
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

MODULE_EUROSHARE_EU_REGEXP_URL="http://\(www\.\)\?euroshare\.eu/"

MODULE_EUROSHARE_EU_DOWNLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free-membership"
MODULE_EUROSHARE_EU_DOWNLOAD_RESUME=no
MODULE_EUROSHARE_EU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

# Output a euroshare.eu file download URL
# $1: cookie file
# $2: euroshare.eu url
# stdout: real file download link
euroshare_eu_download() {
    eval "$(process_options euroshare_eu "$MODULE_EUROSHARE_EU_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL="$2"
    local BASEURL=$(basename_url "$URL")

    # html returned uses utf-8 charset
    PAGE=$(curl "$URL") || return
    if match "<h2>Súbor sa nenašiel</h2>" "$PAGE"; then
        log_error "File not found."
        return $ERR_LINK_DEAD
    elif test "$CHECK_LINK"; then
        return 0
    fi

    if test "$AUTH_FREE"; then
        LOGIN_DATA='login=$USER&pass=$PASSWORD&submit=Prihlásiť sa'
        CHECK_LOGIN=$(post_login "$AUTH_FREE" "$COOKIEFILE" "$LOGIN_DATA" "$BASEURL")

        if ! match "/logout" "$CHECK_LOGIN"; then
            return $ERR_LOGIN_FAILED
        fi
    fi

    # Arbitrary wait (local variable)
    NO_FREE_SLOT_IDLE=125

    # html returned uses utf-8 charset
    PAGE=$(curl -b "$COOKIEFILE" "$URL")

    if match "<h2>Prebieha sťahovanie</h2>" "$PAGE"; then
        log_error "You are already downloading a file from this IP."
        return $ERR_FATAL
    fi

    if match "<center>Všetky sloty pre Free užívateľov sú obsadené." "$PAGE"; then
        echo $NO_FREE_SLOT_IDLE
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    DL_URL=$(echo "$PAGE" | parse_attr '<a class="stiahnut"' 'href')
    if ! test "$DL_URL"; then
        log_error "Can't parse download URL, site updated?"
        return $ERR_FATAL
    fi

    DL_URL=$(curl -I "$DL_URL")

    FILENAME=$(echo "$DL_URL" | grep_http_header_content_disposition)

    FILE_URL=$(echo "$DL_URL" | grep_http_header_location)
    if ! test "$FILE_URL"; then
        log_error "Location not found"
        return $ERR_FATAL
    fi

    echo "$FILE_URL"
    test "$FILENAME" && echo "$FILENAME"

    return 0
}
