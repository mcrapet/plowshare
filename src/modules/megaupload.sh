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
MODULE_MEGAUPLOAD_UPLOAD_OPTIONS="a:,auth-freemembership:,AUTH,USER:PASSWORD
d:,description:,DESCRIPTION,DESCRIPTION"

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
 
    check_exec "convert" || 
        { debug "convert not found (install imagemagick)"; return 1; }       
    check_exec "tesseract" ||
        { debug "tesseract not found (install tesseract-ocr)"; return 1; }
    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$LOGINURL") ||
        { debug "error on login process"; return 1; }    
    TRY=1
    while true; do 
        debug "Downloading waiting page (loop $TRY)"
        TRY=$(($TRY + 1))
        PAGE=$(curl -b <(echo "$COOKIES") "$URL")
        CAPTCHA_URL=$(echo "$PAGE" | parse "gencap.php" 'src="\([^"]*\)"') ||
            { debug "file not found"; return 1; }
        CAPTCHA=$(curl "$CAPTCHA_URL" | \
            convert - -alpha off -colorspace gray -level 1%,1% gif:- | \
            ocr | tr -d -c '[A-Z0-9]')
        debug "Decoded captcha: $CAPTCHA"
        test $(echo -n $CAPTCHA | wc -c) -eq 4 || 
            { debug "Captcha length invalid"; continue; } 
        IMAGECODE=$(echo "$PAGE" | parse "captchacode" 'value="\(.*\)\"')
        MEGAVAR=$(echo "$PAGE" | parse "megavar" 'value="\(.*\)\"')
        DATA="captcha=$CAPTCHA&captchacode=$IMAGECODE&megavar=$MEGAVAR"
        WAITPAGE=$(curl -b <(echo "$COOKIES") --data "$DATA" "$URL")
        WAITTIME=$(echo "$WAITPAGE" | parse "^[[:space:]]*count=" \
            "count=\([[:digit:]]\+\);" || true)
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

# Upload a file to megaupload
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
        "$DONE" | parse "downloadurl" "url = '\(.*\)';"        
}
