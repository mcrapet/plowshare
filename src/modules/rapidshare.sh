#!/bin/bash
#
# Rapidshare module for plowshare.
#
#
#
MODULE_RAPIDSHARE_REGEXP_URL="http://\(www\.\)\?rapidshare.com/files/"

# Output a rapidshare file download URL
#
# $1: A rapidshare URL
#
rapidshare_download() {
    URL=$1
    while true; do
        WAIT_URL=$(curl "$URL" | parse '<form' 'action="\(.*\)"')
        test "$WAIT_URL" || { debug "file not found"; return 1; }
        DATA=$(curl --data "dl.start=Free" "$WAIT_URL")
        test "$DATA" || { debug "can't get wait URL contents"; return 1; }
        LIMIT=$(echo "$DATA" | parse "try again" "\([[:digit:]]\+\) minutes")
        test -z "$LIMIT" && break
        debug "download limit reached: waiting $LIMIT minutes"
        sleep ${LIMIT}m
    done
    DOWNLOADING=$(echo "$DATA" | grep -o "Your IP address.*file")
    test "$DOWNLOADING" && { debug "$DOWNLOADING"; return 2; }
    FILE_URL=$(echo "$DATA" | parse "<form " 'action="\([^\"]*\)"') 
    SLEEP=$(echo "$DATA" | parse "^var c=" "c=\([[:digit:]]\+\);")
    test "$FILE_URL" || { debug "can't get file URL"; return 1; }
    debug "URL File: $FILE_URL" 
    test "$SLEEP" || { debug "can't get sleep time"; SLEEP=100; }
    debug "Waiting $SLEEP seconds" 
    sleep $(($SLEEP + 1))
    echo $FILE_URL    
}

# Upload a file to Rapidshare
#
# $1: File path
# $2/$3: User/password (optional)
#
rapidshare_upload() {
    FILE=$1
    USER=$2
    PASSWORD=$3        
    LOGIN_URL="https://ssl.rapidshare.com/cgi-bin/collectorszone.cgi"
    ANONYMOUS_URL="http://www.rapidshare.com"
    FREEZONE_URL="https://ssl.rapidshare.com/cgi-bin/collectorszone.cgi"
    
    COOKIES=$(post_login "$USER" "$PASSWORD" "$LOGIN_URL" \
        "username=$USER&password=$PASSWORD") ||
        { debug "cannot complete login process"; return 2; }
    test "$COOKIES" && STARTURL=$FREEZONE_URL || STARTURL=$ANONYMOUS_URL
    debug "downloading upload page: $STARTURL"
    ACTION=$(curl -b <(echo "$COOKIES") "$STARTURL" \
        | parse '<form name="ul"' 'action="\([^"]*\)') ||
        { debug "can't get upload action url"; return 2; }
    debug "upload to: $ACTION"    
    INFO=$(curl -b <(echo "$COOKIES") \
        -F "filecontent=@$FILE;filename=$(basename "$FILE")" \
        "$ACTION") || { debug "can't upload file"; return 2; }
    URL=$(echo "$INFO" | parse "downloadlink" ">\(.*\)<")
    KILL=$(echo "$INFO" | parse "loeschlink" ">\(.*\)<")
    echo "$URL ($KILL)"       
}
