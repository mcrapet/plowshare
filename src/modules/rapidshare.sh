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
        sleep ${LIMIT}m
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
    FILE=$1
    UPLOAD_URL="http://www.rapidshare.com"
    FREEZONE_LOGIN_URL="https://ssl.rapidshare.com/cgi-bin/collectorszone.cgi"

    if [ "$AUTH_FREEZONE" ]; then 
        COOKIES=$(post_login "username" "password" \
            "$AUTH_FREEZONE" "$FREEZONE_LOGIN_URL")
        test "$COOKIES" || { debug "error on login process"; return 1; }
    fi
     
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
    if [ "$AUTH_FREEZONE" ]; then     
        MOVE_URL=$(echo "$INFO" | parse "\<form" 'action="\([^"]*\)"')
        debug "Transfering to collectors zone: $MOVE_URL"
        KILLCODE=$(echo "$INFO" | tr '>' '\n' | parse "killcode1" 'value="\([^"]*\)"')
        FILEID=$(echo "$INFO" | tr '>' '\n' | parse "fileid" 'value="\([^"]*\)"')
        IFS=":" read USER PASSWORD <<< "$AUTH_FREEZONE"
        INFO=$(curl \
            -F "move=1" \
            -F "killcode1=$KILLCODE" \
            -F "fileid1=$FILEID" \
            -F "username=$USER" \
            -F "password=$PASSWORD" \
            "$MOVE_URL") || debug "can't transfer to collectors zone"
    fi    
    echo "$URL ($KILL)"
}
