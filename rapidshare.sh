#!/bin/bash
# Rapidshare module for downshare.
#
LIBDIR=$(dirname "$(readlink -f "$(type -P $0)")")
source $LIBDIR/lib.sh

DOWNSHARE_RAPIDSHARE="http://\(www\.\)\?rapidshare.com/files/"

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
