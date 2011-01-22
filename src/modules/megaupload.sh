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

MODULE_MEGAUPLOAD_REGEXP_URL="http://\(www\.\)\?mega\(upload\|rotic\|porn\|video\).com/"
MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Free-membership or Premium account
LINK_PASSWORD,p:,link-password:,PASSWORD,Used in password-protected files
"
MODULE_MEGAUPLOAD_UPLOAD_OPTIONS="
MULTIFETCH,m,multifetch,,Use URL multifetch upload
CLEAR_LOG,,clear-log,,Clear upload log after upload process
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or Premium account
LINK_PASSWORD,p:,link-password:,PASSWORD,Protect a link with a password
DESCRIPTION,d:,description:,DESCRIPTION,Set file description
FROMEMAIL,,email-from:,EMAIL,<From> field for notification email
TOEMAIL,,email-to:,EMAIL,<To> field for notification email
TRAFFIC_URL,,traffic-url:,URL,Set the traffic URL
MULTIEMAIL,,multiemail:,EMAIL1[;EMAIL2;...],List of emails to notify upload
"
MODULE_MEGAUPLOAD_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Login to free or Premium account (required)
"
MODULE_MEGAUPLOAD_LIST_OPTIONS=""
MODULE_MEGAUPLOAD_DOWNLOAD_CONTINUE=yes

# megaupload_download [MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS] URL
#
# Output file URL
#
megaupload_download() {
    set -e
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS" "$@")"

    COOKIES=$(create_tempfile)
    ERRORURL="http://www.megaupload.com/?c=msg"
    URL=$(echo "$1" | replace 'rotic.com/' 'porn.com/' | \
                      replace 'video.com/' 'upload.com/')

    # Arbitrary wait (local variable)
    NO_FREE_SLOT_IDLE=125

    # Try to login (if $AUTH not null)
    if [ -n "$AUTH" ]; then
        LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
        BASEURL=$(basename_url "$URL")
        post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" "$BASEURL/?c=login" >/dev/null || {
            rm -f $COOKIES
            return 1
        }
    fi

    echo $URL | grep -q "\.com/?d=" ||
        URL=$(curl -I "$URL" | grep_http_header_location)

    ccurl() { curl -b "$COOKIES" "$@"; }

    TRY=0
    while retry_limit_not_reached || return 3; do
        TRY=$(($TRY + 1))
        log_debug "Downloading waiting page (loop $TRY)"
        PAGE=$(ccurl "$URL") || { echo "Error getting page: $URL"; return 1; }

        # Test for Premium account with "direct download" option
        if [ -z "$PAGE" ]; then
            ccurl -i "$URL" | grep_http_header_location
            return 0
        fi

        REDIRECT=$(echo "$PAGE" | parse_quiet "document.location" \
            "location[[:space:]]*=[[:space:]]*[\"']\(.*\)[\"']" || true)

        if test "$REDIRECT" = "$ERRORURL"; then
            log_debug "Server returned an error page: $REDIRECT"
            WAITTIME=$(curl "$REDIRECT" | parse 'check back in' \
                'check back in \([[:digit:]]\+\) minute')
            # Fragile parsing, set a default waittime if something went wrong
            test ! -z "$WAITTIME" -a "$WAITTIME" -ge 1 -a "$WAITTIME" -le 20 ||
                WAITTIME=2
            wait $WAITTIME minutes || return 2
            continue

        # Test for big files (premium account required)
        elif match "The file you are trying to download is larger than" "$PAGE"; then
            log_debug "Premium link"
            rm -f $COOKIES
            test "$CHECK_LINK" && return 255
            return 253

        # Test if the file is password protected
        elif match 'name="filepassword"' "$PAGE"; then
            if test "$CHECK_LINK"; then
                rm -f $COOKIES
                return 255
            fi

            log_debug "File is password protected"

            if [ -z "$LINK_PASSWORD" ]; then
                LINK_PASSWORD=$(prompt_for_password) || \
                    { log_error "You must provide a password"; return 4; }
            fi

            DATA="filepassword=$LINK_PASSWORD"

            # We must save HTTP headers to detect premium account
            # (expect "HTTP/1.1 302 Found" return header)
            PAGE=$(ccurl -i -d "$DATA" "$URL")
            HTTPCODE=$(echo "$PAGE" | sed -ne '1s/HTTP\/[^ ]*\s\(...\).*/\1/p')

            if [ "$HTTPCODE"  = "302" ]; then
                echo "$PAGE" | grep_http_header_location
                return 0
            fi

            match 'name="filepassword"' "$PAGE" &&
                { log_error "Link password incorrect"; return 1; }

            WAITTIME=$(echo "$PAGE" | parse_quiet "^[[:space:]]*count=" \
                "count=\([[:digit:]]\+\);") || return 1
            break

        # Test for "come back later". Language is guessed with the help of http-user-agent.
        elif match 'file you are trying to access is temporarily unavailable' "$PAGE"; then
            if test "$NOARBITRARYWAIT"; then
                log_debug "File temporarily unavailable"
                rm -f $COOKIES
                return 253
            fi
            log_debug "Arbitrary wait."
            wait $NO_FREE_SLOT_IDLE seconds || return 2
            continue
        fi

        # Look for a download link (usually a password protected file)
        FILEURL=$(echo "$PAGE" | parse_attr 'id="downloadlink"' 'href' 2>/dev/null)
        if test "$FILEURL"; then
            if test "$CHECK_LINK"; then
                rm -f $COOKIES
                return 255
            fi

            log_debug "Link found, no need to wait"
            echo "$FILEURL"
            return 0
        fi

        # Check for dead link
        if match 'link you have clicked is not available' "$PAGE"; then
            rm -f $COOKIES
            return 254
        fi

        if test "$CHECK_LINK"; then
            rm -f $COOKIES
            return 255
        fi

        # Test for Premium account without "direct download" option
        if match 'flashvars.username' "$PAGE" && [ -n "$AUTH" ]; then
            rm -f $COOKIES

            FILEURL=$(echo "$PAGE" | parse_attr 'class="down_ad_butt1"' 'href')
            echo "$FILEURL"
            return 0
        fi

        CAPTCHA_URL=$(echo "$PAGE" | parse "gencap.php" 'src="\([^"]*\)"') || return 1
        log_debug "captcha URL: $CAPTCHA_URL"

        # OCR captcha and show ascii image to stderr simultaneously
        CAPTCHA=$(curl "$CAPTCHA_URL" | convert - +matte gif:- |
            show_image_and_tee | ocr | sed "s/[^a-zA-Z0-9]//g") ||
            { log_error "error running OCR"; return 1; }
        log_debug "Decoded captcha: $CAPTCHA"
        test "${#CAPTCHA}" -ne 4 &&
            { log_debug "Captcha length invalid"; continue; }

        IMAGECODE=$(echo "$PAGE" | parse "captchacode" 'value="\(.*\)\"')
        MEGAVAR=$(echo "$PAGE" | parse "megavar" 'value="\(.*\)\"')
        DATA="captcha=$CAPTCHA&captchacode=$IMAGECODE&megavar=$MEGAVAR"
        PAGE=$(ccurl --data "$DATA" "$URL")
        WAITTIME=$(echo "$PAGE" | parse_quiet "^[[:space:]]*count=" \
            "count=\([[:digit:]]\+\);" || true)
        test "$WAITTIME" && break;
        log_debug "Wrong captcha"
    done
    rm -f $COOKIES

    FILEURL=$(echo "$PAGE" | parse_attr 'id="downloadlink"' 'href')
    if [ -z "$FILEURL" ]; then
        rm -f $COOKIES
        log_error "Can't parse filename (unexpected characters?)"
        return 1
    fi

    wait $((WAITTIME+1)) seconds

    echo "$FILEURL"
}

# megaupload_upload [UPLOAD_OPTIONS] FILE [DESTFILE]
#
megaupload_upload() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_UPLOAD_OPTIONS" "$@")"
    local FILE=$1
    local DESTFILE=${2:-$FILE}
    local LOGINURL="http://www.megaupload.com/?c=login"
    local BASEURL=$(basename_url "$LOGINURL")

    COOKIES=$(create_tempfile)
    if [ -n "$AUTH" ]; then
        LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
        post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" "$LOGINURL" >/dev/null || {
            rm -f $COOKIES
            return 1
        }
    fi

    if [ "$MULTIFETCH" ]; then
      UPLOADURL="http://www.megaupload.com/?c=multifetch"
      STATUSURL="http://www.megaupload.com/?c=multifetch&s=transferstatus"
      STATUSLOOPTIME=5

      # Cookie file must contain sessionid
      [ -s "$COOKIES" ] ||
          { log_error "Premium account required to use multifetch"; return 2; }

      log_debug "spawn URL fetch process: $FILE"
      UPLOADID=$(curl -b $COOKIES -L \
          -F "fetchurl=$FILE" \
          -F "description=$DESCRIPTION" \
          -F "youremail=$FROMEMAIL" \
          -F "receiveremail=$TOEMAIL" \
          -F "password=$LINK_PASSWORD" \
          -F "multiplerecipients=$MULTIEMAIL" \
          "$UPLOADURL"| parse "estimated_" 'id="estimated_\([[:digit:]]*\)' ) ||
              { log_error "cannot start multifetch upload"; return 2; }
      while true; do
        CSS="display:[[:space:]]*none"
        STATUS=$(curl -b $COOKIES "$STATUSURL")
        ERROR=$(echo "$STATUS" | grep -v "$CSS" | \
            parse_quiet "status_$UPLOADID" '>\(.*\)<\/div>' | xargs) || true
        test "$ERROR" && { log_error "Status reported error: $ERROR"; break; }
        echo "$STATUS" | grep "completed_$UPLOADID" | grep -q "$CSS" || break
        INFO=$(echo "$STATUS" | parse "estimated_$UPLOADID" \
            "estimated_$UPLOADID\">\(.*\)<\/div>" | xargs)
        log_debug "waiting for the upload $UPLOADID to finish: $INFO"
        sleep $STATUSLOOPTIME
      done
      log_debug "fetching process finished"
      STATUS=$(curl -b $COOKIES "$STATUSURL")
      if [ "$CLEAR_LOG" ]; then
        log_debug "clearing upload log for task $UPLOADID"
        CLEARURL=$(echo "$STATUS" | parse "cancel=$UPLOADID" "href=[\"']\([^\"']*\)")
        log_debug "clear URL: $BASEURL/$CLEARURL"
        curl -b $COOKIES "$BASEURL/$CLEARURL" > /dev/null
      fi
      echo "$STATUS" | parse "downloadurl_$UPLOADID" "href=[\"']\([^\"']*\)"
    else
      UPLOADURL="http://www.megaupload.com/multiupload/"
      log_debug "downloading upload page: $UPLOADURL"
      DONE=$(curl "$UPLOADURL" | parse "upload_done.php" 'action="\([^\"]*\)"') ||
          { log_debug "can't get upload_done page"; return 2; }
      UPLOAD_IDENTIFIER=$(parse "IDENTIFIER" "IDENTIFIER=\([0-9.]\+\)" <<< $DONE)
      log_debug "starting file upload: $FILE"
      curl_with_log -b $COOKIES \
          -F "UPLOAD_IDENTIFIER=$UPLOAD_IDENTIFIER" \
          -F "sessionid=$UPLOAD_IDENTIFIER" \
          -F "file=@$FILE;filename=$(basename_file "$DESTFILE")" \
          -F "message=$DESCRIPTION" \
          -F "toemail=$TOEMAIL" \
          -F "fromemail=$FROMEMAIL" \
          -F "password=$LINK_PASSWORD" \
          -F "trafficurl=$TRAFFIC_URL" \
          -F "multiemail=$MULTIEMAIL" \
          "$DONE" | parse "downloadurl" "url = '\(.*\)';"
    fi
    rm -f $COOKIES
}

# megaupload_delete [DELETE_OPTIONS] URL
megaupload_delete() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_DELETE_OPTIONS" "$@")"

    URL=$1
    LOGINURL="http://www.megaupload.com/?c=login"
    AJAXURL="http://www.megaupload.com/?ajax=1"

    test "$AUTH" ||
        { log_error "anonymous users cannot delete links"; return 1; }

    COOKIES=$(create_tempfile)
    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" "$LOGINURL" >/dev/null || {
        rm -f $COOKIES
        return 1
    }

    FILEID=$(echo "$URL" | parse "." "d=\(.*\)")
    DATA="action=deleteItems&items_list[]=file_$FILEID&mode=modeAll&parent_id=0"
    JSCODE=$(curl -b $COOKIES -d "$DATA" "$AJAXURL")

    rm -f $COOKIES

    echo "$JSCODE" | grep -q "file_$FILEID" ||
        { log_error "error deleting link"; return 1; }
}

# List links contained in a Megaupload list URL ($1)
megaupload_list() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_LIST_OPTIONS" "$@")"
    URL=$1
    XMLURL="http://www.megaupload.com/xml/folderfiles.php"
    FOLDERID=$(echo "$URL" | parse '.' 'f=\([^=]\+\)') ||
        { log_error "cannot parse url: $URL"; return 1; }

    XML=$(curl "$XMLURL/?folderid=$FOLDERID")

    if match "<FILES></FILES>" "$XML"; then
        log_debug "empty folder"
        return 0
    fi

    echo "$XML" | parse_all_attr "<ROW" "url"
}
