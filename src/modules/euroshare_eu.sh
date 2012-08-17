#!/bin/bash
#
# euroshare.eu module
# Copyright (c) 2011 halfman <Pulpan3@gmail.com>
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

MODULE_EUROSHARE_EU_REGEXP_URL="http://\(www\.\)\?euroshare\.eu/"

MODULE_EUROSHARE_EU_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_EUROSHARE_EU_DOWNLOAD_RESUME=no
MODULE_EUROSHARE_EU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

# Output a Euroshare.eu file download URL
# $1: cookie file
# $2: euroshare.eu url
# stdout: real file download link
#         file name
euroshare_eu_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.euroshare.eu'
    local PAGE DL_URL

    # HTML returned uses UTF-8 charset
    PAGE=$(curl "$URL") || return

    # <strong>Požadovaný súbor sa na serveri nenachádza alebo bol odstránený</strong>
    match 'Požadovaný súbor sa na serveri nenachádza' "$PAGE" && return $ERR_LINK_DEAD
    [ -n "$CHECK_LINK" ] && return 0

    if [ -n "$AUTH_FREE" ]; then
        local LOGIN_DATA LOGIN_RESULT

        LOGIN_DATA='login=$USER&password=$PASSWORD+&trvale=1'
        LOGIN_RESULT=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/customer-zone/login/" -L) || return

        # <p>Boli ste úspešne prihlásený</p>
        match 'Boli ste úspešne prihlásený' "$LOGIN_RESULT" || return $ERR_LOGIN_FAILED
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

    # <a href="/file/15529848/xyz/download/"><div class="downloadButton" >Stiahnuť</div></a>
    DL_URL="$BASE_URL"$(echo "$PAGE" | \
        parse 'Stiahnuť' 'href="\(/file/.\+/download/\)">') || return
    DL_URL=$(curl -i "$DL_URL") || return

    # Extract + output download link and file name
    echo "$DL_URL" | grep_http_header_location || return
    echo "$PAGE" | parse_tag 'strong' || return
}
