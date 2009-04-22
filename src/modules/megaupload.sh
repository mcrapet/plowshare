#!/bin/bash
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
MODULE_MEGAUPLOAD_REGEXP_URL="http://\(www\.\)\?megaupload.com/"
MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Free-membership or Premium account
LINKPASSWORD,p:,link-password:,PASSWORD,Used in password-protected files
CHECK_LINK,c,check-link,,Check if a link exists and return
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
    ERRORURL="http://www.megaupload.com/?c=msg"
 
    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$LOGINURL") ||
        { error "login process failed"; return 1; }
    ccurl() { curl -b <(echo "$COOKIES") "$@"; }    
    TRY=0
    while true; do 
        TRY=$(($TRY + 1))
        debug "Downloading waiting page (loop $TRY)"
        PAGE=$(ccurl "$URL")
        REDIRECT=$(echo "$PAGE" | parse "document.location" \
          "location[[:space:]]*=[[:space:]]*[\"']\(.*\)[\"']" 2>/dev/null || true)
        if test "$REDIRECT" = "$ERRORURL"; then
          WAITTIME=60
          debug "Server returned an error page: $ERRORURL"
          debug "Waiting $WAITTIME seconds before trying again"
          sleep $WAITTIME
          continue          
        # Test if the file is password protected
        elif match 'name="filepassword"' "$PAGE"; then
            test "$CHECK_LINK" && return 255;
            debug "File is password protected"
            test "$LINKPASSWORD" || 
                { error "You must provide a password"; return 1; }
            PAGE=$(ccurl -d "filepassword=$LINKPASSWORD" "$URL")
            match 'name="filepassword"' "$PAGE" &&
                { error "Link password incorrect"; return 1; } 
        fi        
        # Look for a download link (either Premium account or password
        # protected file)
        FILEURL=$(echo "$PAGE" | grep -A1 'id="downloadlink"' | \
            parse "<a" 'href="\([^"]*\)"' 2>/dev/null || true)
        if test "$FILEURL"; then
            test "$CHECK_LINK" && return 255
            debug "Link found, no need to wait"
            echo "$FILEURL"
            return
        fi 
        CAPTCHA_URL=$(echo "$PAGE" | parse "gencap.php" 'src="\([^"]*\)"') ||
            { error "file not found"; return 1; }
        test "$CHECK_LINK" && return 255;          
        debug "captcha URL: $CAPTCHA_URL"
        COLUMNS=$(tput cols || echo 80)
        LINES=$(tput lines || echo 25)
        # OCR captcha and show ascii image to stderr simultaneously
        CAPTCHA=$(curl "$CAPTCHA_URL" | 
            tee >(test -z "$QUIET" && ascii_image -width $COLUMNS -height $LINES >&2) | \
            megaupload_ocr $(test -z "$QUIET" && echo -vvvv) -) ||
            { error "error running OCR"; return 1; }
        debug "Decoded captcha: $CAPTCHA"
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
# megaupload_upload [OPTIONS] FILE [DESTFILE]
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#   -d DESCRIPTION, --description=DESCRIPTION
#
megaupload_upload() {
    set -e
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_UPLOAD_OPTIONS" "$@")"
    FILE=$1
    DESTFILE=${2:-$FILE}
    UPLOADURL="http://www.megaupload.com"

    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$LOGINURL") ||
        { debug "error on login process"; return 1; }
    debug "downloading upload page: $UPLOADURL"
    DONE=$(curl "$UPLOADURL" | parse "upload_done.php" 'action="\([^\"]*\)"') ||
        { debug "can't get upload_done page"; return 2; }    
    UPLOAD_IDENTIFIER=$(parse "IDENTIFIER" "IDENTIFIER=\([0-9.]\+\)" <<< $DONE)
    debug "starting file upload: $FILE"
    curl -b <(echo "$COOKIES") \
        -F "UPLOAD_IDENTIFIER=$UPLOAD_IDENTIFIER" \
        -F "sessionid=$UPLOAD_IDENTIFIER" \
        -F "file=@$FILE;filename=$(basename "$DESTFILE")" \
        -F "message=$DESCRIPTION" \
        -F "toemail=$TOEMAIL" \
        -F "fromemail=$FROMEMAIL" \
        -F "password=$PASSWORD" \
        -F "trafficurl=$TRAFFIC_URL" \
        -F "multiemail=$MULTIEMAIL" \
        "$DONE" | parse "downloadurl" "url = '\(.*\)';"
}
