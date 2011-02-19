#!/bin/bash
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
#
# Author: halfman <Pulpan3@gmail.com>

MODULE_EUROSHARE_EU_REGEXP_URL="http://\(www\.\)\?euroshare\.eu/"
MODULE_EUROSHARE_EU_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Free-membership or Premium account (required)"
MODULE_EUROSHARE_EU_DOWNLOAD_CONTINUE=no

# Output a euroshare.eu file download URL
# $1: EUROSHARE_EU_URL
# stdout: real file download link
euroshare_eu_download() {
    set -e
    eval "$(process_options euroshare_eu "$MODULE_EUROSHARE_EU_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    COOKIES=$(create_tempfile)
    BASEURL=$(basename_url "$URL")

    # Arbitrary wait (local variable)
    NO_FREE_SLOT_IDLE=125

    while retry_limit_not_reached || return 3; do

        # html returned uses utf-8 charset
        PAGE=$(curl --location "$URL")
        if match "<h2>Súbor sa nenašiel</h2>" "$PAGE"; then
            log_error "File not found."
            rm -f $COOKIES
            return 254
        elif match "<h2>Prebieha sťahovanie</h2>" "$PAGE"; then
            log_error "You are already downloading a file from this IP."
            rm -f $COOKIES
            return 255
        fi

        if ! test "$AUTH"; then
            log_error "At least Free-membership is needed for downloading."
            rm -f $COOKIES
            test "$CHECK_LINK" && return 255
            return 1
        fi

        LOGIN_DATA='login=$USER&pass=$PASSWORD&submit=Prihlásiť sa'
        CHECK_LOGIN=$(post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" "$BASEURL/login")

        DOWNLOAD_PAGE=$(curl -b "$COOKIES" --location "$URL")

        rm -f $COOKIES

        if ! match "<h2>Ste úspešne prihlásený</h2>" "$CHECK_LOGIN"; then
            log_error "Login process failed. Bad username or password."
            test "$CHECK_LINK" && return 255
            return 1
        fi

        if match "<center>Všetky sloty pre Free užívateľov sú obsadené." "$DOWNLOAD_PAGE"; then
            if test "$NOARBITRARYWAIT"; then
                log_debug "File temporarily unavailable"
                return 253
            fi
            log_debug "Arbitrary wait."
            wait $NO_FREE_SLOT_IDLE seconds || return 2
            continue
        fi
        break
    done

    DL_URL=$(echo "$DOWNLOAD_PAGE" | parse_attr '<div class="right">' 'href')
    if ! test "$DL_URL"; then
        log_error "Can't parse download URL, site updated?"
        return 255
    fi

    DL_URL=$(curl -I "$DL_URL")

    FILENAME=$(echo "$DL_URL" | grep_http_header_content_disposition)

    FILE_URL=$(echo "$DL_URL" | grep_http_header_location)
    if ! test "$FILE_URL"; then
        log_error "Location not found"
        return 255
    fi

    test "$CHECK_LINK" && return 255

    echo "$FILE_URL"
    test "$FILENAME" && echo "$FILENAME"

    return 0
}
