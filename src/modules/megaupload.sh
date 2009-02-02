#!/bin/bash
#
# Megaupload module for plowshare.
#
# Dependencies: curl, JS interpreter (rhino, spidermonkey, ...), 
#               convert (imagemagick), tesseract-ocr
#
#
MODULE_MEGAUPLOAD_REGEXP_URL="http://\(www\.\)\?megaupload.com/"
MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS="a:,auth:,AUTH,USER:PASSWORD"
MODULE_MEGAUPLOAD_UPLOAD_OPTIONS="a:,auth:,AUTH,USER:PASSWORD
d:,description:,DESCRIPTION,DESCRIPTION"

LOGINURL="http://www.megaupload.com"

# Output a megaupload file download URL
#
# megaupload_download [OPTIONS] MEGAUPLOAD_URL
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#
megaupload_download() {
    eval "$(process_options "$MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS" "$@")"             
    URL=$1
    BASEURL="http://www.megaupload.com"
 
    check_exec "js" || check_exec "smjs" || check_exec "rhino" || 
        { debug "no javascript interpreter (js/smjs) found"; return 1; }
    check_exec "convert" || 
        { debug "convert not found (install imagemagick)"; return 1; }       
    check_exec "tesseract" ||
        { debug "tesseract not found (install tesseract-ocr)"; return 1; }
    COOKIES=$(post_login "login" "password" "$AUTH" "$LOGINURL") ||
        { debug "error on login process"; return 1; }
    TRY=1
    while true; do 
        debug "Downloading waiting page (loop $TRY)"
        TRY=$(expr $TRY + 1)
        PAGE=$(curl -b <(echo "$COOKIES") "$URL")
        CAPTCHA_URL=$(echo "$PAGE" | parse "capgen" 'src="\(.*\)"') ||
            { debug "file not found"; return 1; }    
        CAPTCHA=$(curl "$BASEURL/$CAPTCHA_URL" | \
            convert - -alpha off -colorspace gray gif:- | ocr)
        debug "Decoded captcha: $CAPTCHA"
        test $(echo -n $CAPTCHA | wc -c) -eq 3 || 
            { debug "Captcha length invalid"; continue; } 
        IMAGECODE=$(echo "$PAGE" | parse "imagecode" 'value="\(.*\)\"')
        MEGAVAR=$(echo "$PAGE" | parse "megavar" 'value="\(.*\)\"')
        D=$(echo "$PAGE" | parse 'name="d"' 'value="\(.*\)\"')
        DATA="imagestring=$CAPTCHA&d=$D&imagecode=$IMAGECODE&megavar=$MEGAVAR"
        WAITPAGE=$(curl -b <(echo "$COOKIES") --data "$DATA" "$BASEURL")
        SECVAR=$(echo "$WAITPAGE" | parse "Please wait" "'+\([^+]*\)+'")
        test "$SECVAR" && break;
        debug "Captcha was not accepted"
    done
    WAITTIME=$(echo "$WAITPAGE" | parse "$SECVAR=" "=\(.*\);") ||
        { debug "error getting wait time"; WAITTIME=50; }
    # We could easily parse the Javascript code, but it's nicer 
    # and more robust to tell a JS interpreter to run the code for us.
    JSCODE=$(echo "$WAITPAGE" | grep -B2 'ById("dlbutton")')    
    URLCODE=$(echo "$JSCODE" | parse 'dlbutton' 'href="\([^"]*\)"')
    JSSHELL=$(type -P js smjs rhino | head -n1)
    FILEURL=$({ echo "$JSCODE" | head -n2; \
        echo "print('$URLCODE');"; } | $JSSHELL)
    debug "File URL: $FILEURL"
    debug "Waiting $WAITTIME seconds"
    sleep $(($WAITTIME + 1))
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
    eval "$(process_options "$MODULE_MEGAUPLOAD_UPLOAD_OPTIONS" "$@")"
    FILE=$1
    UPLOADURL="http://www.megaupload.com"

    COOKIES=$(post_login "login" "password" "$AUTH" "$LOGINURL") ||
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
