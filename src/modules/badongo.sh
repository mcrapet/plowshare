#!/bin/bash
#
# Badongo module for plowshare.
#
# License: GNU GPL v3.0: http://www.gnu.org/licenses/gpl-3.0-standalone.html
#
# Dependencies: curl, python, python-imaging
#
MODULE_BADONGO_REGEXP_URL="http://\(www\.\)\?badongo.com/"
MODULE_BADONGO_DOWNLOAD_OPTIONS=
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
        ACTION=$(echo "$JSCODE" | parse "form" 'action=\\"\([^\\]*\)\\"')
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
