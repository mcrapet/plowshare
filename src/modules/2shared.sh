#!/bin/bash
#
# 2shared module for plowshare.
#
MODULE_2SHARED_REGEXP_URL="http://\(www\.\)\?2shared.com/file/"

# Output a 2shared file download URL
#
# $1: A 2shared URL
#
2shared_download() {
    URL=$1   
    FILE_URL=$(curl "$URL" | parse "window.location" "location = \"\(.*\)\";")
    test "$FILE_URL" || { debug "file not found"; return 1; }
    echo $FILE_URL    
}
