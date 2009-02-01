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

# Upload a file to 2shared
#
# $1: File path
#
2shared_upload() {
    FILE=$1
    UPLOADURL="http://www.2shared.com/"

    debug "downloading upload page: $UPLOADURL"
    DATA=$(curl "$UPLOADURL")
    ACTION=$(echo "$DATA" | parse "uploadForm" 'action="\([^"]*\)"')
    COMPLETE=$(echo "$DATA" | parse "uploadComplete" 'location="\([^"]*\)"')
    debug "starting file upload: $FILE"
    STATUS=$(curl -F "mainDC=1" \
        -F "fff=@$FILE;filename=$(basename "$FILE")" \
        "$ACTION")
    match "upload has successfully completed" "$STATUS" ||
        { debug "error on upload"; return 1; }
    curl "$UPLOADURL/$COMPLETE" | parse 'name="downloadLink"' "\(http:[^<]*\)"
}
