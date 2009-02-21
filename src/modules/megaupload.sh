#!/bin/bash
#
# Megaupload module for plowshare.
#
# License: GNU GPL v3.0: http://www.gnu.org/licenses/gpl-3.0-standalone.html
#
# Dependencies: curl, convert (imagemagick), tesseract (tesseract-ocr)
#
MODULE_MEGAUPLOAD_REGEXP_URL="http://\(www\.\)\?megaupload.com/"
MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS="a:,auth:,AUTH,USER:PASSWORD"
MODULE_MEGAUPLOAD_UPLOAD_OPTIONS="a:,auth:,AUTH,USER:PASSWORD
d:,description:,DESCRIPTION,DESCRIPTION
f:,email-from:,FROMEMAIL,EMAIL
t:,email-to:,TOEMAIL,EMAIL
p:,link-password:,PASSWORD,STRING
,traffic-url:,TRAFFIC_URL,URL
m:,multiemail:,MULTIEMAIL,EMAIL1[,EMAIL2,...]
"

LOGINURL="http://www.megaupload.com/?c=login"

# Output a megaupload file download URL
#
# megaupload_download [OPTIONS] MEGAUPLOAD_URL
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#
megaupload_download() {
    set -e
    eval "$(process_options "$MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS" "$@")"             
    URL=$1
    BASEURL="http://www.megaupload.com"
 
    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$LOGINURL") ||
        { debug "error on login process"; return 1; }    
    TRY=1
    while true; do 
        debug "Downloading waiting page (loop $TRY)"
        TRY=$(($TRY + 1))
        PAGE=$(curl -b <(echo "$COOKIES") "$URL")
        # Test if we are using a premium account, try to get downloadlink
        FILEURL=$(echo "$PAGE" |grep -A1 'id="downloadlink"' | \
            tail -n1 | parse "<a" 'href="\([^"]*\)"')
        if test "$FILEURL"; then
            debug "Premium account, there is no need to wait"
            debug "File URL: $FILEURL"
            echo "$FILEURL"
            return
        fi 
        CAPTCHA_URL=$(echo "$PAGE" | parse "gencap.php" 'src="\([^"]*\)"') ||
            { debug "file not found"; return 1; }
        CAPTCHA=$(curl "$CAPTCHA_URL" | \
            convert - -alpha off -colorspace gray -level 1%,1% gif:- | \
            ocr | xargs | tr -d -c '[A-Z0-9]')
        debug "Decoded captcha: $CAPTCHA"
        test $(echo -n $CAPTCHA | wc -c) -eq 4 || 
            { debug "Captcha length invalid"; continue; } 
        IMAGECODE=$(echo "$PAGE" | parse "captchacode" 'value="\(.*\)\"')
        MEGAVAR=$(echo "$PAGE" | parse "megavar" 'value="\(.*\)\"')
        DATA="captcha=$CAPTCHA&captchacode=$IMAGECODE&megavar=$MEGAVAR"
        WAITPAGE=$(curl -b <(echo "$COOKIES") --data "$DATA" "$URL")
        WAITTIME=$(echo "$WAITPAGE" | parse "^[[:space:]]*count=" \
            "count=\([[:digit:]]\+\);" 2>/dev/null || true)
        test "$WAITTIME" && break;
        debug "Wrong captcha"
    done
    FILEURL=$(echo "$WAITPAGE" | grep "downloadlink" | \
        parse 'id="downloadlink"' 'href="\([^"]*\)"')
    debug "File URL: $FILEURL"
    debug "Waiting $WAITTIME seconds"
    sleep $WAITTIME
    echo "$FILEURL"    
}

# Upload a file to megaupload and upload url link
#
# megaupload_upload [OPTIONS] FILE
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#   -d DESCRIPTION, --description=DESCRIPTION
#
megaupload_upload() {
    set -e
    eval "$(process_options "$MODULE_MEGAUPLOAD_UPLOAD_OPTIONS" "$@")"
    FILE=$1
    UPLOADURL="http://www.megaupload.com"

    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$LOGINURL") ||
        { debug "error on login process"; return 1; }
    debug "downloading upload page: $UPLOADURL"
    DONE=$(curl "$UPLOADURL" | parse "upload_done.php" 'action="\([^\"]*\)"') ||
        { debug "can't get upload_done page"; return 2; }    
    UPLOAD_IDENTIFIER=$(parse "IDENTIFIER" "IDENTIFIER=\([0-9.]\+\)" <<< $DONE)
    debug "starting file upload: $DONE"
    curl -b <(echo "$COOKIES") \
        -F "UPLOAD_IDENTIFIER=$UPLOAD_IDENTIFIER" \
        -F "sessionid=$UPLOAD_IDENTIFIER" \
        -F "file=@$FILE;filename=$(basename "$FILE")" \
        -F "message=$DESCRIPTION" \
        -F "toemail=$TOEMAIL" \
        -F "fromemail=$FROMEMAIL" \
        -F "password=$PASSWORD" \
        -F "trafficurl=$TRAFFIC_URL" \
        -F "multiemail=$MULTIEMAIL" \
        "$DONE" | parse "downloadurl" "url = '\(.*\)';"
}
