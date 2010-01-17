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
MODULE_MEGAUPLOAD_REGEXP_URL="^http://\(www\.\)\?mega\(upload\|rotic\|porn\).com/"
MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Free-membership or Premium account
LINKPASSWORD,p:,link-password:,PASSWORD,Used in password-protected files
"
MODULE_MEGAUPLOAD_UPLOAD_OPTIONS="
MULTIFETCH,m,multifetch,,Use URL multifetch upload
CLEAR_LOG,,clear-log,,Clear upload log after upload process
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or Premium account
PASSWORD,p:,link-password:,PASSWORD,Protect a link with a password
DESCRIPTION,d:,description:,DESCRIPTION,Set file description
FROMEMAIL,,email-from:,EMAIL,<From> field for notification email
TOEMAIL,,email-to:,EMAIL,<To> field for notification email
TRAFFIC_URL,,traffic-url:,URL,Set the traffic URL
MULTIEMAIL,,multiemail:,EMAIL1[;EMAIL2;...],List of emails to notify upload
"
MODULE_MEGAUPLOAD_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Login to free or Premium account (required)
"
MODULE_MEGAUPLOAD_DOWNLOAD_CONTINUE=yes

# megaupload_download [DOWNLOAD_OPTIONS] URL
#
# Output file URL
#
megaupload_download() {
    set -e
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS" "$@")"

    ERRORURL="http://www.megaupload.com/?c=msg"
    URL=$(echo "$1" | sed "s/rotic\.com/porn\.com/")
    BASEURL=$(echo "$URL" | grep -o "http://[^/]*")

    # Try to login (if $AUTH not null)
    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$BASEURL/?c=login") ||
        { error "login process failed"; return 1; }
    echo $URL | grep -q "\.com/?d=" ||
        URL=$(curl -I "$URL" | grep_http_header_location)
    ccurl() { curl -b <(echo "$COOKIES") "$@"; }

    TRY=0
    while true; do
        TRY=$(($TRY + 1))
        debug "Downloading waiting page (loop $TRY)"
        PAGE=$(ccurl "$URL") || { echo "Error getting page: $URL"; return 1; }

        # A void page means this is a Premium account, get the URL
        test -z "$PAGE" && { ccurl -i "$URL" | get_location; return; }

        REDIRECT=$(echo "$PAGE" | parse "document.location" \
            "location[[:space:]]*=[[:space:]]*[\"']\(.*\)[\"']" 2>/dev/null || true)

        if test "$REDIRECT" = "$ERRORURL"; then
            debug "Server returned an error page: $REDIRECT"
            WAITTIME=$(curl "$REDIRECT" | parse 'check back in' \
                'check back in \([[:digit:]]\+\) minute')
            # Fragile parsing, set a default waittime if something went wrong
            test ! -z "$WAITTIME" -a "$WAITTIME" -ge 1 -a "$WAITTIME" -le 20 ||
                WAITTIME=2
            countdown $WAITTIME 1 minutes 60
            continue

        # Test if the file is password protected
        elif match 'name="filepassword"' "$PAGE"; then
            test "$CHECK_LINK" && return 255;
            debug "File is password protected"
            test "$LINKPASSWORD" ||
                { error "You must provide a password"; return 1; }
            DATA="filepassword=$LINKPASSWORD"
            PAGE=$(ccurl -d "$DATA" "$URL")
            match 'name="filepassword"' "$PAGE" &&
                { error "Link password incorrect"; return 1; }
            WAITPAGE=$(ccurl -d "$DATA" "$URL")
            match 'name="filepassword"' "$WAITPAGE" 2>/dev/null &&
                { error "Link password incorrect"; return 1; }
            #test -z "$PAGE" &&
            #    { ccurl -i -d "$DATA" "$URL" | get_location; return; }
            WAITTIME=$(echo "$WAITPAGE" | parse "^[[:space:]]*count=" \
                "count=\([[:digit:]]\+\);" 2>/dev/null) || return 1
            break

        # Test for "come back later". Language is guessed with the help of http-user-agent.
        elif match 'file you are trying to access is temporarily unavailable' "$PAGE"; then
            debug "File temporarily unavailable"
            test "$CHECK_LINK" && return 255
            WAITTIME=2
            countdown $WAITTIME 1 minutes 60
            continue
        fi

        # Look for a download link (usually a password protected file)
        FILEURL=$(echo "$PAGE" | grep -A1 'id="downloadlink"' | \
            parse "<a" 'href="\([^"]*\)"' 2>/dev/null || true)
        if test "$FILEURL"; then
            test "$CHECK_LINK" && return 255
            debug "Link found, no need to wait"
            echo "$FILEURL"
            return
        fi

        match 'link you have clicked is not available' "$PAGE" && return 254

        test "$CHECK_LINK" && return 255

        CAPTCHA_URL=$(echo "$PAGE" | parse "gencap.php" 'src="\([^"]*\)"') || return 1
        debug "captcha URL: $CAPTCHA_URL"
        # OCR captcha and show ascii image to stderr simultaneously
        CAPTCHA=$(curl "$CAPTCHA_URL" | convert - +matte gif:- |
            show_image_and_tee | ocr | sed "s/[^a-zA-Z0-9]//g") ||
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

    FILEURL=$(echo "$WAITPAGE" | grep "downloadlink" | \
        parse 'id="downloadlink"' 'href="\([^"]*\)"')
    countdown $((WAITTIME+1)) 10 seconds 1

    echo "$FILEURL"
}

# megaupload_upload [UPLOAD_OPTIONS] FILE [DESTFILE]
#
megaupload_upload() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_UPLOAD_OPTIONS" "$@")"
    FILE=$1
    DESTFILE=${2:-$FILE}
    LOGINURL="http://www.megaupload.com/?c=login"

    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$LOGINURL") ||
        { debug "error on login process"; return 1; }

    if [ "$MULTIFETCH" ]; then
      UPLOADURL="http://www.megaupload.com/?c=multifetch"
      STATUSURL="http://www.megaupload.com/?c=multifetch&s=transferstatus"
      STATUSLOOPTIME=5
      [ -z "$COOKIES" ] &&
          { error "Premium account required to use multifetch"; return 2; }
      debug "spawn URL fetch process: $FILE"
      UPLOADID=$(curl -b <(echo "$COOKIES") -L \
          -F "fetchurl=$FILE" \
          -F "description=$DESCRIPTION" \
          -F "youremail=$FROMEMAIL" \
          -F "receiveremail=$TOEMAIL" \
          -F "password=$PASSWORD" \
          -F "multiplerecipients=$MULTIEMAIL" \
          "$UPLOADURL"| parse "estimated_" 'id="estimated_\([[:digit:]]*\)' ) ||
              { error "cannot start multifetch upload"; return 2; }
      while true; do
        CSS="display:[[:space:]]*none"
        STATUS=$(curl -s -b <(echo "$COOKIES") "$STATUSURL")
        ERROR=$(echo "$STATUS" | grep -v "$CSS" | \
            parse "status_$UPLOADID" '>\(.*\)<\/div>' 2>/dev/null | xargs) || true
        test "$ERROR" && { error "Status reported error: $ERROR"; break; }
        echo "$STATUS" | grep "completed_$UPLOADID" | grep -q "$CSS" || break
        INFO=$(echo "$STATUS" | parse "estimated_$UPLOADID" \
            "estimated_$UPLOADID\">\(.*\)<\/div>" | xargs)
        debug "waiting for the upload $UPLOADID to finish: $INFO"
        sleep $STATUSLOOPTIME
      done
      debug "fetching process finished"
      STATUS=$(curl -b <(echo "$COOKIES") "$STATUSURL")
      if [ "$CLEAR_LOG" ]; then
        debug "clearing upload log for task $UPLOADID"
        CLEARURL=$(echo "$STATUS" | parse "cancel=$UPLOADID" "href=[\"']\([^\"']*\)")
        debug "clear URL: $BASEURL/$CLEARURL"
        curl -b <(echo "$COOKIES") "$BASEURL/$CLEARURL" > /dev/null
      fi
      echo "$STATUS" | parse "downloadurl_$UPLOADID" "href=[\"']\([^\"']*\)"
    else
      UPLOADURL="http://www.megaupload.com"
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
    fi
}

# megaupload_delete [DELETE_OPTIONS] URL
#
megaupload_delete() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_DELETE_OPTIONS" "$@")"
    URL=$1
    LOGINURL="http://www.megaupload.com/?c=login"

    AJAXURL="http://www.megaupload.com/?ajax=1"
    test "$AUTH" ||
        { error "anonymous users cannot delete links"; return 1; }
    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$LOGINURL") ||
        { error "error on login process"; return 1; }
    FILEID=$(echo "$URL" | parse "." "d=\(.*\)")
    DATA="action=deleteItems&items_list[]=file_$FILEID&mode=modeAll&parent_id=0"
    JSCODE=$(curl -b <(echo "$COOKIES") -d "$DATA" "$AJAXURL")
    echo "$JSCODE" | grep -q "file_$FILEID" ||
        { error "error deleting link"; return 1; }
}

get_location() {
    grep "^[Ll]ocation:" | head -n1 | cut -d":" -f2- | xargs
}
