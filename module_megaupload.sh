#!/bin/bash
#
# Megaupload module for plowshare.
#
# Dependencies: curl, smjs (spidermonkey)
#
set -e
LIBDIR=$(dirname "$(readlink -f "$(type -P $0)")")
source $LIBDIR/lib.sh

DOWNSHARE_MEGAUPLOAD="http://\(www\.\)\?megaupload.com/"

LOGINURL="http://www.megaupload.com"
BASEURL="http://www.megaupload.com"

# Output a megaupload file download URL
#
# $1: A megaupload URL
# $2/$3: User/Password (optional)
#
megaupload_download() {
    URL=$1
    USER=$2
    PASSWORD=$3
 
    check_exec "smjs" "smjs not found (install spidermonkey)"       
    TRY=1
    COOKIES=$(post_login "$USER" "$PASSWORD" "$LOGINURL" \
        "login=$USER&password=$PASSWORD")
    while true; do 
        debug "Downloading waiting page (loop $TRY)"
        TRY=$(expr $TRY + 1)
        PAGE=$(curl -b <(echo "$COOKIES") "$URL")
        CAPTCHA_URL=$(echo "$PAGE" | parse "capgen" 'src="\(.*\)"')
        test "$CAPTCHA_URL" || { debug "file not found"; return 1; }    
        CAPTCHA=$(curl "$BASEURL/$CAPTCHA_URL" | convert - txt:- | \
            sed "s/rgba$/rgb/" | \
            sed "s/(255,255,255,255).*$/(255,255,255)/;" | \
            sed "/,  0)/ s/: .*$/: (1,1,1)/" | ocr)
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
    # We could easily parse the Javascript code, but it's nicer 
    # and more robust to tell a JS interpreter to run the code for us.
    JSCODE=$(echo "$WAITPAGE" | grep -B2 'ById("dlbutton")')    
    URLCODE=$(echo "$JSCODE" | parse 'dlbutton' 'href="\([^"]*\)"')
    FILEURL=$({ echo "$JSCODE" | head -n2; echo "print('$URLCODE');"; } | smjs)
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
    DESCRIPTION=$2    
    USER=$3
    PASSWORD=$4        
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
