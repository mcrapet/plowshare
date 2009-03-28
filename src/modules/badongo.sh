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
MODULE_BADONGO_REGEXP_URL="http://\(www\.\)\?badongo.com/"
MODULE_BADONGO_DOWNLOAD_OPTIONS="
CHECK_LINK,c,check-link,,Check if a link exists and return"
MODULE_BADONGO_UPLOAD_OPTIONS=
MODULE_BADONGO_DOWNLOAD_CONTINUE=yes

# Output a file URL to download from Badongo
#
# badongo_download [OPTIONS] BADONGO_URL
#
badongo_download() {
    set -e
    eval "$(process_options bandogo "$MODULE_BADONGO_DOWNLOAD_OPTIONS" "$@")"
    URL=$1
    BASEURL="http://www.badongo.com"
    COOKIES=$(create_tempfile)
    TRY=1
    while true; do 
        debug "Downloading captcha page (loop $TRY)"
        TRY=$(($TRY + 1))
        JSCODE=$(curl \
            -F "rs=refreshImage" \
            -F "rst=" \
            -F "rsrnd=$MTIME" \
            "$URL" | sed "s/>/>\n/g") 
        ACTION=$(echo "$JSCODE" | parse "form" 'action=\\"\([^\\]*\)\\"') ||
            { debug "file not found"; return 1; }
        test "$CHECK_LINK" && return 255
        CAP_IMAGE=$(echo "$JSCODE" | parse '<img' 'src=\\"\([^\\]*\)\\"')
        MTIME="$(date +%s)000"
        CAPTCHA=$(curl $BASEURL$CAP_IMAGE | \
            convert - -alpha off -colorspace gray -level 40%,40% gif:- | \
            ocr | tr -c -d "[a-zA-Z]" | uppercase)
        debug "Decoded captcha: $CAPTCHA"
        test $(echo -n $CAPTCHA | wc -c) -eq 4 || 
            { debug "Captcha length invalid"; continue; }             
        CAP_ID=$(echo "$JSCODE" | parse 'cap_id' 'value="\?\([^">]*\)')
        CAP_SECRET=$(echo "$JSCODE" | parse 'cap_secret' 'value="\?\([^">]*\)')
        WAIT_PAGE=$(curl -c $COOKIES \
            -F "cap_id=$CAP_ID" \
            -F "cap_secret=$CAP_SECRET" \
            -F "user_code=$CAPTCHA" \
            "$ACTION")
        match "var waiting" "$WAIT_PAGE" && break
        debug "Wrong captcha"          
   done
    WAIT_TIME=$(echo "$WAIT_PAGE" | parse 'var check_n' 'check_n = \([[:digit:]]\+\)')
    LINK_PAGE=$(echo "$WAIT_PAGE" | parse 'req.open("GET"' '"GET", "\(.*\)\/status"')
    debug "Waiting $WAIT_TIME seconds"
    sleep $WAIT_TIME
    FILE_URL=$(curl -i -b $COOKIES $LINK_PAGE | \
        grep "^Location:" | head -n1 | cut -d" " -f2- | sed "s/[[:space:]]*$//")
    rm -f $COOKIES
    debug "File URL: $FILE_URL"
    echo "$FILE_URL"    
}
