#!/bin/bash
#
# Megaupload module for plowshare.
#
# License: GNU GPL v3.0: http://www.gnu.org/licenses/gpl-3.0-standalone.html
#
# Dependencies: curl, python, python-imaging, aview (for manual captcha)
#
MODULE_MEGAUPLOAD_REGEXP_URL="http://\(www\.\)\?megaupload.com/"
MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Free-membership or Premium account
LINKPASSWORD,p:,link-password:,PASSWORD,Used in password-protected files
USEDB,,use-captcha-database,,Use JDownloader catpcha database (if fails, switch to OCR moe)
INPUT_CAPTCHA,,input-captcha,,Prompt user to enter the captcha manually
"
MODULE_MEGAUPLOAD_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or Premium account
DESCRIPTION,d:,description:,DESCRIPTION,Set file description
FROMEMAIL,f:,email-from:,EMAIL,<From> field for notification email
TOEMAIL,t:,email-to:,EMAIL,<To> field for notification email
PASSWORD,p:,link-password:,PASSWORD,Protect a link with a password
TRAFFIC_URL,,traffic-url:,URL,Set the traffic URL
MULTIEMAIL,m:,multiemail:,EMAIL1[;EMAIL2;...],List of emails to notify upload
"
MODULE_MEGAUPLOAD_DOWNLOAD_CONTINUE=yes

LOGINURL="http://www.megaupload.com/?c=login"

# Output image in ascii chars (uses aview)
#
ascii_image() {
    asciiview -kbddriver stdin -driver stdout <(cat) 2>/dev/null <<< "q" | \
        awk 'BEGIN { part = 0; }
            /\014/ { part++; next; }
            // { if (part == 2) print $0; }'  | \
        grep -v "^[[:space:]]*$"
}

# Output a megaupload file download URL
#
# megaupload_download [OPTIONS] MEGAUPLOAD_URL
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#
megaupload_download() {
    set -e
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS" "$@")"
    URL=$1
    BASEURL="http://www.megaupload.com"
 
    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    MAXDBTRIES=5
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$LOGINURL") ||
        { debug "error on login process"; return 1; }
    ccurl() { curl -b <(echo "$COOKIES") "$@"; }    
    TRY=0
    while true; do 
        if [ "$USEDB" -a $TRY -eq $MAXDBTRIES ]; then
            debug "After $MAXDBTRIES no captcha was found in database"
            debug "Switch to OCR mode"
            USEDB=
        fi
        TRY=$(($TRY + 1))
        debug "Downloading waiting page (loop $TRY)"
        PAGE=$(ccurl "$URL")
        # Test if the file is password protected
        if match 'name="filepassword"' "$PAGE"; then
            debug "File is password protected"
            test "$LINKPASSWORD" || 
                { debug "You must provide a password"; return 1; }
            PAGE=$(ccurl -d "filepassword=$LINKPASSWORD" "$URL")
            match 'name="filepassword"' "$PAGE" &&
                { debug "Link password incorrect"; return 1; } 
        fi        
        # Test if we are using a Premium account, try to get the download link
        FILEURL=$(echo "$PAGE" | grep -A1 'id="downloadlink"' | \
            parse "<a" 'href="\([^"]*\)"' 2>/dev/null || true)
        if test "$FILEURL"; then
            debug "Link found in HTML, no need to wait"
            debug "File URL: $FILEURL"
            echo "$FILEURL"
            return
        fi 
        CAPTCHA_URL=$(echo "$PAGE" | parse "gencap.php" 'src="\([^"]*\)"') ||
            { debug "file not found"; return 1; }
        debug "captcha URL: $CAPTCHA_URL"
        if test "$INPUT_CAPTCHA"; then
            curl "$CAPTCHA_URL" | ascii_image >&2
            echo -n "Enter captcha: " >&2
            read CAPTCHA
            debug "User captcha: $CAPTCHA"
        elif test "$USEDB"; then
            CAPTCHA=$(megaupload_captcha_db <(curl "$CAPTCHA_URL")) ||
                { debug "cannot find captcha in database"; continue; }
            debug "Captcha from database: $CAPTCHA"
        else
            OCR="megaupload_ocr"        
            test "$QUIET" = 1 && OCR="megaupload_ocr -q"
            CAPTCHA=$($OCR <(curl "$CAPTCHA_URL")) || 
                { debug "error running OCR (is python-imaging installed?)"; return 1; }
            debug "Decoded captcha: $CAPTCHA"
        fi
        test $(echo -n $CAPTCHA | wc -c) -eq 4 || 
            { debug "Captcha length invalid"; continue; } 
        IMAGECODE=$(echo "$PAGE" | parse "captchacode" 'value="\(.*\)\"')
        MEGAVAR=$(echo "$PAGE" | parse "megavar" 'value="\(.*\)\"')
        DATA="captcha=$CAPTCHA&captchacode=$IMAGECODE&megavar=$MEGAVAR"
        WAITPAGE=$(ccurl --data "$DATA" "$URL")
        WAITTIME=$(echo "$WAITPAGE" | parse "^[[:space:]]*count=" \
            "count=\([[:digit:]]\+\);" 2>/dev/null || true)
        test "$WAITTIME" && break;
        debug "Wrong captcha"
    done
    debug "Correct captch (try $TRY)"
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
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_UPLOAD_OPTIONS" "$@")"
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
