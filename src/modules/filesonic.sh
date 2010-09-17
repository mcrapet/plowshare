#!/opt/bin/bash
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.
#
# Author: Thomas Jensen (September 2010)

MODULE_FILESONIC_REGEXP_URL="http://\(www\.\)\?\(sharingmatrix\|filesonic\).com/\(en/\)\?\(file\|folder\)/"
MODULE_FILESONIC_DOWNLOAD_OPTIONS=""
MODULE_FILESONIC_UPLOAD_OPTIONS=
MODULE_FILESONIC_DOWNLOAD_CONTINUE=no
MODULE_FILESONIC_LIST_OPTIONS=

# Output a FILESONIC file download URL
#
# $1: A filesonic URL
#
filesonic_download() {
    set -e
    eval "$(process_options filesonic "$MODULE_FILESONIC_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    COOKIES=$(create_tempfile)
    while true
    do
        $(curl -c $COOKIES -o /dev/null "$URL")
        MAIN_PAGE=$(curl -L -b $COOKIES "$URL") || { rm -f $COOKIES; return 1; } 
        if match 'Error 9005: File not found' "$MAIN_PAGE"; then
             rm -f $COOKIES; log_debug "file not found, possibly deleted"; return 254;
        fi
        FILE_URL_TEMP=$(echo "$MAIN_PAGE" | parse "downloadNow.*free_download" "href=\"\([^\"]*\)" 2>/dev/null) || { rm -f $COOKIES; return 1; } 
        if test "$CHECK_LINK"; then
            rm -f $COOKIES; 
            return 255;
        fi

        # Try to figure out real name written on page
        FILE_REAL_NAME=$(echo "$MAIN_PAGE" | parse "<title>Download" "Download \(.*\) for free - FileSonic" 2>/dev/null)
        log_debug got real file name $FILE_REAL_NAME
        # Load the timer with redirection
        TIMER_PAGE=$(curl -L -b $COOKIES "$FILE_URL_TEMP" 2>/dev/null) || { rm -f $COOKIES; return 1; }
        # If download session in progess, wait 5 minutes, and try again, otherwise continue
        if match 'Download session in progress' "$TIMER_PAGE"; then
            log_debug Download session in progress \(or you just downloaded >100MB\)
            log_debug Waiting 10 minutes and try again
            wait 601 seconds || { rm -f $COOKIES; return 2; }
            continue
        fi
        if match 'Free user can not download files over 400MB' "$TIMER_PAGE"; then
            log_debug Free user can not download files over 400MB... skipping...
            rm -f $COOKIES; 
            return 253;
        fi                                                                        
        
        break
    done

    SLEEP=$(echo "$TIMER_PAGE" | parse "var countDownDelay" "countDownDelay[^0-9]*\([0-9]*\)" 2>/dev/null)
    FILE_URL=$(echo "$TIMER_PAGE" | parse "var downloadUrl" "downloadUrl[^\"]*\"\([^\"]\+\)" 2>/dev/null)
    log_debug Must wait $SLEEP seconds, then you may load $FILE_URL
    wait $((SLEEP + 1)) seconds || {  rm -f $COOKIES; return 2; }

    log_debug Fetching "$FILE_REAL_NAME"
    echo "$FILE_URL"
    test -n "$FILE_REAL_NAME" && echo "$FILE_REAL_NAME"
    test -n "$COOKIES" && echo "$COOKIES"
    test -c "$COOKIES" && rm -f $COOKIES
    return 0
}


# List a filesonic shared file folder URL
# $1: FILESONIC_URL
# stdout: list of links
filesonic_list() {
    eval "$(process_options filesonic "$MODULE_FILESONIC_LIST_OPTIONS" "$@")"
    URL=$1

    if ! match '\(www\.\)\?\(sharingmatrix\|filesonic\).com/folder\/' "$URL"; then
        log_error "This is not a directory list"
        return 1
    fi

    PAGE=$(curl -L "$URL" | grep 'href=.*\(sharingmatrix\|filesonic\).com/\(en/\)\?file/')
    if test -z "$PAGE"; then
        log_error "Wrong directory list link.. unable to load"
        return 1
    fi

    # First pass : print debug message
    echo "$PAGE" | while read LINE; do
        FILENAME=$(echo "$LINE" | parse 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILENAME"
    done

    # Second pass : print links (stdout)
    echo "$PAGE" | while read LINE; do
        LINK=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$LINK"
    done

    return 0
}
