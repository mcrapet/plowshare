#!/bin/bash
#
# Rapidshare module for plowshare.
#
#
#
MODULE_RAPIDSHARE_REGEXP_URL="http://\(www\.\)\?rapidshare.com/files/"
MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS=
MODULE_RAPIDSHARE_UPLOAD_OPTIONS="a:,auth-freezone:,AUTH_FREEZONE,USER:PASSWORD"

# Output a rapidshare file download URL (anonymous, NOT PREMIUM)
#
# rapidshare_download RAPIDSHARE_URL
#
rapidshare_download() {
    URL=$1
    while true; do
        WAIT_URL=$(curl "$URL" | parse '<form' 'action="\(.*\)"') ||
            { debug "file not found"; return 1; }
        DATA=$(curl --data "dl.start=Free" "$WAIT_URL") ||
            { debug "can't get wait URL contents"; return 1; }
        LIMIT=$(echo "$DATA" | parse "try again" "\([[:digit:]]\+\) minutes")
        test -z "$LIMIT" && break
        debug "download limit reached: waiting $LIMIT minutes"
        sleep $((LIMIT*60))
    done
    DOWNLOADING=$(echo "$DATA" | grep -o "Your IP address.*file") &&
        { debug "$DOWNLOADING"; return 2; }
    FILE_URL=$(echo "$DATA" | parse "<form " 'action="\([^\"]*\)"') ||
        { debug "can't get file URL"; return 1; } 
    SLEEP=$(echo "$DATA" | parse "^var c=" "c=\([[:digit:]]\+\);") ||
        { debug "can't get sleep time"; SLEEP=100; }
    debug "URL File: $FILE_URL" 
    debug "Waiting $SLEEP seconds" 
    sleep $(($SLEEP + 1))
    echo $FILE_URL    
}

# Upload a file to Rapidshare (anonymously or free zone, NOT PREMIUM)
#
# rapidshare_upload [OPTIONS] FILE
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#
rapidshare_upload() {
    eval "$(process_options "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"    
    if [ "$AUTH_FREEZONE" ]; then
        rapidshare_upload_freezone "$@"
    else
        rapidshare_upload_anonymous "$@" 
    fi
}

# Upload a file to Rapidshare anonymously
#
# rapidshare_upload [OPTIONS] FILE
#
#
rapidshare_upload_anonymous() {
    FILE=$1
    UPLOAD_URL="http://www.rapidshare.com"
    debug "downloading upload page: $UPLOAD_URL"
    ACTION=$(curl "$UPLOAD_URL" | parse 'form name="ul"' 'action="\([^"]*\)') ||
        { debug "can't get upload action url"; return 2; }
    debug "upload to: $ACTION"    
    INFO=$(curl -F "filecontent=@$FILE;filename=$(basename "$FILE")" "$ACTION") ||      
        { debug "can't upload file"; return 2; }
    URL=$(echo "$INFO" | parse "downloadlink" ">\(.*\)<") ||
        { debug "can't get download link"; return 2; }        
    KILL=$(echo "$INFO" | parse "loeschlink" ">\(.*\)<") ||
        { debug "can't get kill link"; return 2; }     
    echo "$URL ($KILL)"
}

# Upload a file to Rapidshare (free zone)
#
# rapidshare_upload [OPTIONS] FILE
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#
rapidshare_upload_freezone() {
    eval "$(process_options "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"
    FILE=$1
    FREEZONE_LOGIN_URL="https://ssl.rapidshare.com/cgi-bin/collectorszone.cgi"
       
    if [ "$AUTH_FREEZONE" ]; then 
        COOKIES=$(post_login "username" "password" \
            "$AUTH_FREEZONE" "$FREEZONE_LOGIN_URL")
        test "$COOKIES" || { debug "error on login process"; return 1; }
    fi
    ccurl() { curl -b <(echo "$COOKIES") "$@"; }
    debug "downloading upload page: $UPLOAD_URL"
    UPLOAD_PAGE=$(ccurl $FREEZONE_LOGIN_URL)
    ACCOUNTID=$(echo "$UPLOAD_PAGE" | \
        parse 'name="freeaccountid"' 'value="\([[:digit:]]*\)"')
    ACTION=$(echo "$UPLOAD_PAGE" | parse '<form name="ul"' 'action="\([^"]*\)"')
    IFS=":" read USER PASSWORD <<< "$AUTH_FREEZONE"
    debug "uploading file: $FILE"
    UPLOADED_PAGE=$(ccurl \
        -F "filecontent=@$FILE;filename=$(basename "$FILE")" \
        -F "freeaccountid=$ACCOUNTID" \
        -F "password=$PASSWORD" \
        -F "mirror=on" $ACTION)
    debug "download upload page to get url: $FREEZONE_LOGIN_URL"
    UPLOAD_PAGE=$(ccurl $FREEZONE_LOGIN_URL)
    FILEID=$(echo "$UPLOAD_PAGE" | grep ^Adliste | tail -n1 | \
        parse Adliste 'Adliste\["\([[:digit:]]*\)"')
    MATCH="^Adliste\[\"$FILEID\"\]"
    KILLCODE=$(echo "$UPLOAD_PAGE" | parse "$MATCH" "\[\"killcode\"\] = '\(.*\)'")
    FILENAME=$(echo "$UPLOAD_PAGE" | parse "$MATCH" "\[\"filename\"\] = \"\(.*\)\"")
    # There is a killcode in the HTML, but it's not used to build a URL
    # but as a param in a POST, so I assume there is no kill URL for
    # freezone. Therefore, output only the file URL.    
    URL="http://rapidshare.com/files/$FILEID/$FILENAME.html"
    echo "$URL"
}
