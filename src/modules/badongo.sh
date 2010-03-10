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

MODULE_BADONGO_REGEXP_URL="http://\(www\.\)\?badongo\.com/"
MODULE_BADONGO_DOWNLOAD_OPTIONS=""
MODULE_BADONGO_UPLOAD_OPTIONS=
MODULE_BADONGO_DOWNLOAD_CONTINUE=no

# Output a file URL to download from Badongo
#
# badongo_download [MODULE_BADONGO_DOWNLOAD_OPTIONS] BADONGO_URL
#
badongo_download() {
    set -e
    eval "$(process_options bandogo "$MODULE_BADONGO_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    BASEURL="http://www.badongo.com"

    PAGE=$(curl "$URL")
    echo "$PAGE" | grep -q '"recycleMessage">' &&
        { log_debug "file in recycle bin"; return 254; }
    echo "$PAGE" | grep -q '"fileError">' &&
        { log_debug "file not found"; return 254; }

    COOKIES=$(create_tempfile)
    TRY=1

    while retry_limit_not_reached || return 3; do
        log_debug "Downloading captcha page (loop $TRY)"
        TRY=$(($TRY + 1))
        JSCODE=$(curl \
            -F "rs=refreshImage" \
            -F "rst=" \
            -F "rsrnd=$MTIME" \
            "$URL" | sed "s/>/>\n/g")
        ACTION=$(echo "$JSCODE" | parse "form" 'action=\\"\([^\\]*\)\\"') ||
            { log_debug "file not found"; return 254; }

        if test "$CHECK_LINK"; then
            rm -f $COOKIES
            return 255
        fi

        CAP_IMAGE=$(echo "$JSCODE" | parse '<img' 'src=\\"\([^\\]*\)\\"')
        MTIME="$(date +%s)000"
        CAPTCHA=$(curl $BASEURL$CAP_IMAGE | \
            convert - +matte -colorspace gray -level 40%,40% gif:- | \
            show_image_and_tee | ocr upper | sed "s/[^a-zA-Z]//g" | uppercase)
        log_debug "Decoded captcha: $CAPTCHA"
        test $(echo -n $CAPTCHA | wc -c) -eq 4 ||
            { log_debug "Captcha length invalid"; continue; }

        CAP_ID=$(echo "$JSCODE" | parse 'cap_id' 'value="\?\([^">]*\)')
        CAP_SECRET=$(echo "$JSCODE" | parse 'cap_secret' 'value="\?\([^">]*\)')
        WAIT_PAGE=$(curl -c $COOKIES \
            -F "cap_id=$CAP_ID" \
            -F "cap_secret=$CAP_SECRET" \
            -F "user_code=$CAPTCHA" \
            "$ACTION")
        match "var waiting" "$WAIT_PAGE" && break
        log_debug "Wrong captcha"
    done

    WAIT_TIME=$(echo "$WAIT_PAGE" | parse 'var check_n' 'check_n = \([[:digit:]]\+\)') || return 1
    LINK_PAGE=$(echo "$WAIT_PAGE" | parse 'req.open("GET"' '"GET", "\(.*\)\/status"') || return 1

    log_debug "Correct captcha!"

    # usual wait time is 60 seconds
    countdown $((WAIT_TIME)) 5 seconds 1 || return 2

    FILE_URL=$(curl -i -b $COOKIES $LINK_PAGE | grep_http_header_location)
    rm -f $COOKIES
    test "$FILE_URL" || { log_error "location not found"; return 1; }
    echo "$FILE_URL"
}
