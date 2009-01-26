#!/bin/bash
#
# Megaupload module for plowshare.
#
# Dependencies: curl, js/smjs (spidermonkey), convert (imagemagick), tesseract
#
#
MODULE_MEGAUPLOAD_REGEXP_URL="http://\(www\.\)\?megaupload.com/"

LOGINURL="http://www.megaupload.com"

# Output a megaupload file download URL
#
# $1: A megaupload URL
# $2/$3: User/Password (optional)
#
megaupload_download() {
    URL=$1
    USER=$2
    PASSWORD=$3
    BASEURL="http://www.megaupload.com"
 
    check_exec "js" || check_exec "smjs" || 
        { debug "no javascript interpreter (js/smjs) found"; return 1; }
    check_exec "convert" || 
        { debug "convert not found (install imagemagick)"; return 1; }       
    check_exec "tesseract" ||
        { debug "tesseract not found (install tesseract-ocr)"; return 1; }
    COOKIES=$(post_login "$USER" "$PASSWORD" "$LOGINURL" \
        "login=$USER&password=$PASSWORD")
    TRY=1
    while true; do 
        debug "Downloading waiting page (loop $TRY)"
        TRY=$(expr $TRY + 1)
        PAGE=$(curl -b <(echo "$COOKIES") "$URL")
        CAPTCHA_URL=$(echo "$PAGE" | parse "capgen" 'src="\(.*\)"')
        test "$CAPTCHA_URL" || { debug "file not found"; return 1; }    
        CAPTCHA=$(curl "$BASEURL/$CAPTCHA_URL" | \
            convert - -alpha off -colorspace gray gif:- | ocr)
        debug "Decoded captcha: $CAPTCHA"
        test $(echo -n $CAPTCHA | wc -c) -eq 3 || 
            { debug "Captcha length invalid"; continue; } 
        IMAGECODE=$(echo "$PAGE" | parse "imagecode" 'value="\(.*\)\"')
        MEGAVAR=$(echo "$PAGE" | parse "megavar" 'value="\(.*\)\"')
        D=$(echo "$PAGE" | parse 'name="d"' 'value="\(.*\)\"')
        DATA="imagestring=$CAPTCHA&d=$D&imagecode=$IMAGECODE&megavar=$MEGAVAR"
        WAITPAGE=$(curl -b <(echo "$COOKIES")  --data "$DATA" "$BASEURL")
        SECVAR=$(echo "$WAITPAGE" | parse "Please wait" "'+\([^+]*\)+'")
        test "$SECVAR" && break;
        debug "Captcha was not accepted"
    done
    WAITTIME=$(echo "$WAITPAGE" | parse "$SECVAR=" "=\(.*\);")
    test "$WAITTIME" || { debug "error getting wait time"; WAITTIME=50; }
    # We could easily parse the Javascript code, but it's nicer 
    # and more robust to tell a JS interpreter to run the code for us.
    # The only downside: adding the js/smjs dependence.
    JSCODE=$(echo "$WAITPAGE" | grep -B2 'ById("dlbutton")')    
    URLCODE=$(echo "$JSCODE" | parse 'dlbutton' 'href="\([^"]*\)"')
    JSSHELL=$(type -P js smjs | head -n1)
    FILEURL=$({ echo "$JSCODE" | head -n2; echo "print('$URLCODE');"; } | $JSSHELL)
    debug "File URL: $FILEURL"
    debug "Waiting $WAITTIME seconds"
    sleep "$WAITTIME"
    echo "$FILEURL"    
}

# Upload a file to megaupload
#
# $1: File path
# $2: Description
# $3/$4: User/password (optional)
#
megaupload_upload() {
    FILE=$1
    USER=$2
    PASSWORD=$3        
    DESCRIPTION=$4    
    UPLOADURL="http://www.megaupload.com"

    COOKIES=$(post_login "$USER" "$PASSWORD" "$LOGINURL" \
        "login=$USER&password=$PASSWORD")
    debug "downloading upload page: $UPLOADURL"
    DONE=$(curl "$UPLOADURL" | parse "upload_done.php" 'action="\([^\"]*\)"')
    test "$DONE" || { debug "can't get upload_done page"; return 2; }    
    UPLOAD_IDENTIFIER=$(parse "IDENTIFIER" "IDENTIFIER=\([0-9.]\+\)" <<< $DONE)
    debug "starting file upload: $DONE"
    curl -b <(echo "$COOKIES") \
        -F "UPLOAD_IDENTIFIER=$UPLOAD_IDENTIFIER" \
        -F "sessionid=$UPLOAD_IDENTIFIER" \
        -F "file=@$FILE;filename=$(basename "$FILE")" \
        -F "message=$DESCRIPTION" \
        "$DONE" | parse "downloadurl" "url = '\(.*\)';"        
}
