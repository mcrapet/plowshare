#!/bin/bash
#
# megaupload.com module
# Copyright (c) 2010-2011 Plowshare team
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
LINK_PASSWORD,p:,link-password:,PASSWORD,Used in password-protected files"
MODULE_MEGAUPLOAD_DOWNLOAD_RESUME=yes
MODULE_MEGAUPLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_MEGAUPLOAD_UPLOAD_OPTIONS="
MULTIFETCH,m,multifetch,,Use URL multifetch upload
CLEAR_LOG,,clear-log,,Clear upload log after upload process
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or Premium account
LINK_PASSWORD,p:,link-password:,PASSWORD,Protect a link with a password (premium only)
DESCRIPTION,d:,description:,DESCRIPTION,Set file description
FROMEMAIL,,email-from:,EMAIL,<From> field for notification email
TOEMAIL,,email-to:,EMAIL,<To> field for notification email
MULTIEMAIL,,multiemail:,EMAIL1[;EMAIL2;...],List of emails to notify upload"
MODULE_MEGAUPLOAD_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Login to free or Premium account (required)"
MODULE_MEGAUPLOAD_LIST_OPTIONS=""

# Output a megaupload file download URL
# $1: cookie file
# $2: megaupload (or similar) url
# stdout: real file download link
megaupload_download() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL=$(echo "$2" | replace 'rotic.com/' 'porn.com/' | \
                            replace 'video.com/' 'upload.com/')
    local BASEURL=$(basename_url "$URL")
    local ERRORURL="http://www.megaupload.com/?c=msg"

    # Arbitrary wait (local variable)
    NO_FREE_SLOT_IDLE=125

    # Try to login (if $AUTH not null)
    if [ -n "$AUTH" ]; then
        LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
        post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" "$BASEURL/?c=login" >/dev/null || return
    fi

    TRY=0
    while retry_limit_not_reached || return; do
        TRY=$(($TRY + 1))
        log_debug "Downloading waiting page (loop $TRY)"
        PAGE=$(curl -b "$COOKIEFILE" "$URL") || { echo "Error getting page: $URL"; return 1; }

        # Test for Premium account with "direct download" option
        if [ -z "$PAGE" ]; then
            curl -i -b "$COOKIEFILE" "$URL" | grep_http_header_location
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
            wait $WAITTIME minutes || return
            continue

        # Check for dead link
        elif match 'link you have clicked is not available' "$PAGE"; then
            return $ERR_LINK_DEAD

        # Test for big files (premium account required)
        elif match "The file you are trying to download is larger than" "$PAGE"; then
            log_debug "Premium link"
            test "$CHECK_LINK" && return 0
            return $ERR_LINK_NEED_PERMISSIONS

        # Test if the file is password protected
        elif match 'name="filepassword"' "$PAGE"; then
            test "$CHECK_LINK" && return 0

            log_debug "File is password protected"

            if [ -z "$LINK_PASSWORD" ]; then
                LINK_PASSWORD=$(prompt_for_password) || return
            fi

            DATA="filepassword=$LINK_PASSWORD"

            # We must save HTTP headers to detect premium account
            # (expect "HTTP/1.1 302 Found" return header)
            PAGE=$(curl -i -b "$COOKIEFILE" -d "$DATA" "$URL")
            HTTPCODE=$(echo "$PAGE" | sed -ne '1s/HTTP\/[^ ]*\s\(...\).*/\1/p')

            # Premium account with "direct download" option
            if [ "$HTTPCODE"  = "302" ]; then
                echo "$PAGE" | grep_http_header_location
                return 0
            fi

            match 'name="filepassword"' "$PAGE" &&
                { log_error "Link password incorrect"; return 1; }

            if [ -z "$AUTH" ]; then
                WAITTIME=$(echo "$PAGE" | parse_quiet "^[[:space:]]*count=" \
                    "count=\([[:digit:]]\+\);") || return
                break
            fi

        # Test for "come back later". Language is guessed with the help of http-user-agent.
        elif match 'file you are trying to access is temporarily unavailable' "$PAGE"; then
            no_arbitrary_wait || return
            wait $NO_FREE_SLOT_IDLE seconds || return
            continue
        fi

        # ---

        test "$CHECK_LINK" && return 0

        # Test for Premium account without "direct download" option
        ACC=$(curl -b $COOKIEFILE "$BASEURL/?c=account")

        if ! match '<b>Regular</b>' "$ACC" && test "$AUTH"; then
            FILEURL=$(echo "$PAGE" | parse_attr 'class="down_ad_butt1"' 'href')
            echo "$FILEURL"
            return 0
        fi

        # Look for a download link (anonymous & Free account)
        FILEURL=$(echo "$PAGE" | parse_attr_quiet 'id="downloadlink"' 'href')
        if test "$FILEURL"; then
            WAITTIME=$(echo "$PAGE" | parse_quiet "^[[:space:]]*count=" \
                "count=\([[:digit:]]\+\);") || return
            break
        fi

        # There's no more captcha on megaupload!
        log_error "unknown state, site updated?"
        return $ERR_FATAL
    done

    FILEURL=$(echo "$PAGE" | parse_attr 'id="downloadlink"' 'href')
    if [ -z "$FILEURL" ]; then
        log_error "Can't parse filename (unexpected characters?)"
        return $ERR_FATAL
    fi

    wait $((WAITTIME+1)) seconds || return

    echo "$FILEURL"
}

# Upload a file to megaupload
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link on megaupload
megaupload_upload() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local FILE="$2"
    local DESTFILE="$3"
    local LOGINURL="http://www.megaupload.com/?c=login"
    local BASEURL=$(basename_url "$LOGINURL")

    if [ -n "$AUTH" ]; then
        LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
        post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" "$LOGINURL" >/dev/null || return
    elif [ -n "$LINK_PASSWORD" ]; then
        log_error "password ignored, premium only"
    fi

    if [ "$MULTIFETCH" ]; then
        UPLOADURL="http://www.megaupload.com/?c=multifetch"
        STATUSURL="http://www.megaupload.com/?c=multifetch&s=transferstatus"
        STATUSLOOPTIME=5

        # Cookie file must contain sessionid
        [ -s "$COOKIEFILE" ] || return $ERR_LOGIN_FAILED

        log_debug "spawn URL fetch process: $FILE"
        UPLOADID=$(curl -b "$COOKIEFILE" -L \
            -F "fetchurl=$FILE" \
            -F "description=$DESCRIPTION" \
            -F "youremail=$FROMEMAIL" \
            -F "receiveremail=$TOEMAIL" \
            -F "password=$LINK_PASSWORD" \
            -F "multiplerecipients=$MULTIEMAIL" \
            "$UPLOADURL"| parse "estimated_" 'id="estimated_\([[:digit:]]*\)' ) ||
                { log_error "cannot start multifetch upload"; return 1; }
        while true; do
            CSS="display:[[:space:]]*none"
            STATUS=$(curl -b "$COOKIEFILE" "$STATUSURL")
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
        STATUS=$(curl -b "$COOKIEFILE" "$STATUSURL")
        if [ "$CLEAR_LOG" ]; then
            log_debug "clearing upload log for task $UPLOADID"
            CLEARURL=$(echo "$STATUS" | parse "cancel=$UPLOADID" "href=[\"']\([^\"']*\)")
            log_debug "clear URL: $BASEURL/$CLEARURL"
            curl -b "$COOKIEFILE" "$BASEURL/$CLEARURL" > /dev/null
        fi
        echo "$STATUS" | parse "downloadurl_$UPLOADID" "href=[\"']\([^\"']*\)"

    else
        UPLOADURL="http://www.megaupload.com/multiupload/"
        log_debug "downloading upload page: $UPLOADURL"

        local PAGE=$(curl "$UPLOADURL")
        local FORM_URL=$(grep_form_by_name "$PAGE" 'uploadform' | parse_form_action)
        local UPLOAD_ID=$(echo "$FORM_URL" | parse 'IDENTIFIER' '=\(.*\)')

        log_debug "starting file upload: $FILE"

        PAGE=$(curl_with_log -b "$COOKIEFILE" \
            -F "UPLOAD_IDENTIFIER=$UPLOAD_ID" \
            -F "sessionid=$UPLOAD_ID" \
            -F "file=@$FILE;filename=$DESTFILE" \
            -F "message=$DESCRIPTION" \
            -F "toemail=$TOEMAIL" \
            -F "fromemail=$FROMEMAIL" \
            -F "password=$LINK_PASSWORD" \
            -F "multiemail=$MULTIEMAIL" \
            "$FORM_URL") || return

        echo "$PAGE" | parse "downloadurl" "url = '\([^']*\)"

        # This is a trick for free account to set a password
        if [ -n "$AUTH" -a -n "$LINK_PASSWORD" ]; then
            ACC=$(curl -b "$COOKIEFILE" "$BASEURL/?c=account") || return
            if match '<b>Regular</b>' "$ACC"; then
                local ID=$(echo "$PAGE" | parse "downloadurl" "d=\([^']*\)");
                local T="$(date +%s)000"
                PAGE=$(curl -b "$COOKIEFILE" \
                    --data "action=edit&id=${ID}&name=${DESTFILE}&description=${DESCRIPTION}&password=$LINK_PASSWORD" \
                    'http://www.megaupload.com/?c=filemanager&ajax=1&r=${T}') || return
                echo "$PAGE" >/tmp/a
            fi
        fi

    fi
}

# Delete a file on megaupload (requires an account)
# $1: delete link
megaupload_delete() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_DELETE_OPTIONS" "$@")"

    local URL=$1
    local BASE_URL=$(basename_url $URL)

    if ! test "$AUTH"; then
        log_error "Anonymous users cannot delete links."
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    COOKIES=$(create_tempfile)
    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" $BASE_URL"/?c=login" >/dev/null || {
        rm -f $COOKIES
        return $ERR_FATAL
    }

    TOTAL_FILES=$(curl -b $COOKIES $BASE_URL"/?c=account" | \
        parse_all '<strong>' '<strong>*\([^<]*\)' | nth_line 3)

    FILEID=$(echo "$URL" | parse "." "d=\(.*\)")
    DATA="action=delete&delids=$FILEID"
    DELETE=$(curl -b $COOKIES -d "$DATA" $BASE_URL"/?c=filemanager&ajax=1") || return

    rm -f $COOKIES

    FILES=$(echo "$DELETE" | parse_quiet 'totalfiles' 'totalfiles":"\(.*\)","noresults":')

    if [ $TOTAL_FILES -eq $FILES ]; then
        log_error "error deleting link"
        return $ERR_FATAL
    fi
}

# List a megaupload shared file folder URL
# $1: megaupload folder url (http://www.megaupload.com/?f=...)
# stdout: list of links
megaupload_list() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_LIST_OPTIONS" "$@")"

    local URL=$1
    local XMLURL="http://www.megaupload.com/xml/folderfiles.php"
    local XML FOLDERID

    FOLDERID=$(echo "$URL" | parse '.' 'f=\([^=]\+\)') || return
    XML=$(curl "$XMLURL/?folderid=$FOLDERID") || return

    if match "<FILES></FILES>" "$XML"; then
        log_debug "empty folder"
        return 0
    fi

    echo "$XML" | parse_all_attr "<ROW" "url"
}
