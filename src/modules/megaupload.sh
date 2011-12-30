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

MODULE_MEGAUPLOAD_REGEXP_URL="http://\(www\.\)\?mega\(upload\|video\)\.com/"

MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account
LINK_PASSWORD,p:,link-password:,PASSWORD,Used in password-protected files"
MODULE_MEGAUPLOAD_DOWNLOAD_RESUME=yes
MODULE_MEGAUPLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_MEGAUPLOAD_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account
LINK_PASSWORD,p:,link-password:,PASSWORD,Protect a link with a password (premium only)
DESCRIPTION,d:,description:,DESCRIPTION,Set file description
FROMEMAIL,,email-from:,EMAIL,<From> field for notification email
TOEMAIL,,email-to:,EMAIL,<To> field for notification email
MULTIEMAIL,,multiemail:,EMAIL1[;EMAIL2;...],List of emails to notify upload (premium only)
CLEAR_FETCH_LIST,,clear-fetch-list,,Clear fetch list (multifietch, premium only)"
MODULE_MEGAUPLOAD_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account (mandatory)"
MODULE_MEGAUPLOAD_LIST_OPTIONS=""

# Output a megaupload file download URL
# $1: cookie file
# $2: megaupload (or similar) url
# stdout: real file download link
megaupload_download() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL=$(echo "$2" | replace 'video.com/' 'upload.com/')
    local BASEURL=$(basename_url "$URL")
    local FILEID LOGIN_DATA PAGE HTTPCODE ACC WAITTIME FILE_URL

    # URL schemes:
    # - http://www.megaupload.com/?d=xxx
    # - http://www.megaupload.com/en/?d=xxx
    FILEID=$(echo "$URL" | parse "." "d=\(.*\)") || return
    URL="${BASEURL}/?d=$FILEID"

    # Try to login (if $AUTH not null)
    if [ -n "$AUTH" ]; then
        LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
        post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" "$BASEURL/?c=login" >/dev/null || return
    fi

    # We must save HTTP headers to detect premium account
    # (expect "HTTP/1.1 302 Found" and empty Content-Length headers)
    PAGE=$(curl -i -b "$COOKIEFILE" "$URL") || return
    HTTPCODE=$(echo "$PAGE" | sed -ne '1s/HTTP\/[^ ]*\s\(...\).*/\1/p')

    # Premium account with "direct downloads" option
    if [ "$HTTPCODE"  = '302' ]; then
        echo "$PAGE" | grep_http_header_location
        return 0
    fi

    # Check for dead link
    if matchi 'Invalid link' "$PAGE"; then
        return $ERR_LINK_DEAD

    # Test for big files (premium account required)
    elif match '<div class="download_large_main">' "$PAGE"; then
        log_debug "Premium link"
        return $ERR_LINK_NEED_PERMISSIONS

    # Test if the file is password protected
    elif match 'name="filepassword"' "$PAGE"; then
        test "$CHECK_LINK" && return $ERR_LINK_PASSWORD_REQUIRED

        log_debug "File is password protected"

        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        PAGE=$(curl -i -b "$COOKIEFILE" --data "filepassword=$LINK_PASSWORD" "$URL") || return
        HTTPCODE=$(echo "$PAGE" | sed -ne '1s/HTTP\/[^ ]*\s\(...\).*/\1/p')

        # Premium account with "direct downloads" option
        if [ "$HTTPCODE"  = '302' ]; then
            echo "$PAGE" | grep_http_header_location
            return 0
        fi

        if match 'name="filepassword"' "$PAGE"; then
            log_error "Link password incorrect"
            return $ERR_LINK_PASSWORD_REQUIRED
        fi

    # Test for "come back later". Language is guessed with the help of http-user-agent.
    elif match 'file you are trying to access is temporarily unavailable' "$PAGE"; then
        echo 125
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # ---

    test "$CHECK_LINK" && return 0

    if [ -n "$AUTH" ]; then
        # Test for premium account without "direct downloads" option
        ACC=$(curl -b $COOKIEFILE "$BASEURL/?c=account") || return

        if ! match '">Regular' "$ACC" && test "$AUTH"; then
            FILE_URL=$(echo "$PAGE" | parse_attr 'class="download_premium_but"' 'href')
            echo "$FILE_URL"
            return 0
        fi
    fi

    # Look for a download link (anonymous & free account)
    FILE_URL=$(echo "$PAGE" | parse_attr_quiet 'class="download_regular_usual' 'href') || return

    WAITTIME=$(echo "$PAGE" | parse_quiet "^[[:space:]]*count=" \
            "count=\([[:digit:]]\+\);") || return

    wait $((WAITTIME+1)) seconds || return

    echo "$FILE_URL"
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
    local BASE_URL='http://www.megaupload.com'
    local LOGIN_DATA PAGE ACC FORM_URL UPLOAD_ID

    if [ -n "$AUTH" ]; then
        LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
        post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" "$BASE_URL/?c=login" >/dev/null || return

        # Detect account type
        PAGE=$(curl -b "$COOKIEFILE" "$BASE_URL/?c=account") || return
        if match '">Regular' "$PAGE"; then
            ACC=free
        else
            ACC=premium
        fi
    else
        ACC=anonymous

        if [ -n "$LINK_PASSWORD" ]; then
            log_error "password ignored, premium only"
            LINK_PASSWORD=""
        fi

        if [ -n "$MULTIEMAIL" ]; then
            log_error "multiple recipients ignored, premium only"
            MULTIEMAIL=""
        fi
    fi

    # Test for "HTTP / FTP file fetching"
    if match_remote_url "$FILE"; then

        # Feature is for premium users
        if [ "$ACC" != 'premium' ]; then
            log_error "Remote file fetching is for premium users only"
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        PAGE=$(curl -b "$COOKIEFILE" -L \
            -F "fetchurl=$FILE" \
            -F "description=$DESCRIPTION" \
            -F "youremail=$FROMEMAIL" \
            -F "receiveremail=$TOEMAIL" \
            -F "password=$LINK_PASSWORD" \
            -F "multiplerecipients=$MULTIEMAIL" \
            "$BASE_URL/?c=multifetch") || return

        UPLOAD_ID=$(echo "$PAGE" | parse "estimated_" 'id="estimated_\([[:digit:]]*\)' ) || return
        log_debug "upload id:$UPLOAD_ID"

        local CSS='display:[[:space:]]*none'
        local TEXT1 TEXT2 TEXT3

        while true; do
            PAGE=$(curl -b "$COOKIEFILE" "$BASE_URL/?c=multifetch&s=transferstatus") || return

            TEXT3=$(echo "$PAGE" | sed -e "/$CSS/d" | parse_quiet "id=\"completed_$UPLOAD_ID\"" '">\(.*\)<\/div>')
            match '100%' "$TEXT3" && break

            # Experienced states:
            # - Pending
            # - Fetch in progress
            TEXT1=$(echo "$PAGE" | sed -e "/$CSS/d" | parse "id=\"status_$UPLOAD_ID\"" '">\([^<]*\)<\/font>') || return
            log_debug "Status: $TEXT1"
            #TEXT2=$(echo "$PAGE" | sed -e "/$CSS/d" | parse_quiet "id=\"estimated_$UPLOAD_ID\"" '">\([^<]*\)<\/div>')
            #log_debug "[$TEXT2]"

            wait 10 seconds || return
        done

        echo "$PAGE" | parse_attr "downloadurl_$UPLOAD_ID" 'href'

        if [ -n "$CLEAR_FETCH_LIST" ]; then
            log_debug "clear fetch list, as requested"
            curl -b "$COOKIEFILE" -o /dev/null "$BASE_URL/?c=multifetch&s=transferstatus&clear=1" || return
        fi

    else
        # Sanity check
        [ -n "$CLEAR_FETCH_LIST" ] && \
            log_debug "unexpected option --clear-fetch-list, ignoring"

        PAGE=$(curl -b "$COOKIEFILE" "$BASE_URL/multiupload/") || return

        FORM_URL=$(grep_form_by_name "$PAGE" 'uploadform' | parse_form_action)
        UPLOAD_ID=$(echo "$FORM_URL" | parse 'IDENTIFIER' '=\(.*\)')

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
        if [ "$ACC" = 'free' ]; then
            local ID=$(echo "$PAGE" | parse "downloadurl" "d=\([^']*\)");
            local T="$(date +%s)000"
            curl -b "$COOKIEFILE" -o /dev/null \
                --data "action=edit&id=${ID}&name=${DESTFILE}&description=${DESCRIPTION}&password=$LINK_PASSWORD" \
                "$BASE_URL/?c=filemanager&ajax=1&r=$T" || return
        fi
    fi
}

# Delete a file on megaupload (requires an account)
# $1: delete link (is actually download link)
megaupload_delete() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_DELETE_OPTIONS" "$@")"

    local URL="$1"
    local BASE_URL='http://www.megaupload.com'
    local COOKIEFILE LOGIN_DATA TOTAL_FILES FILEID HTML FILES

    if ! test "$AUTH"; then
        log_error "Anonymous users cannot delete links."
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FILEID=$(echo "$URL" | parse_quiet "." "d=\(.*\)")
    if [ -n "$FILEID" ]; then
        URL=$(echo "$2" | replace 'video.com/' 'upload.com/')
    else
        # Assuming megavideo
        FILEID=$(echo "$URL" | parse "." "v=\(.*\)") || return
        BASE_URL=$(basename_url $URL)
    fi

    COOKIEFILE=$(create_tempfile)
    LOGIN_DATA='login=1&redir=1&username=$USER&password=$PASSWORD'
    post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" "$BASE_URL/?c=login" >/dev/null || {
        rm -f "$COOKIEFILE";
        return $ERR_FATAL;
    }

    if match 'megavideo' "$URL"; then
        HTML=$(curl -b "$COOKIEFILE" -d "action=delete&delids=$FILEID" "$BASE_URL/?c=videomanager&ajax=1") || return
        rm -f "$COOKIEFILE"
    else
        # Filemanager is in flash, use "Total files uploaded" info
        TOTAL_FILES=$(curl -b "$COOKIEFILE" "$BASE_URL/?c=account" | parse_line_after \
            'Total files uploaded' '">[[:space:]]*\([[:digit:]]\+\)') || return

        HTML=$(curl -b "$COOKIEFILE" -d "action=delete&delids=$FILEID" "$BASE_URL/?c=filemanager&ajax=1") || return
        rm -f "$COOKIEFILE"

        FILES=$(echo "$HTML" | parse 'totalfiles' 'totalfiles":"\(.*\)","noresults":') || return

        if [ "$TOTAL_FILES" -eq "$FILES" ]; then
            log_error "error deleting link, are you owning the link?"
            return $ERR_FATAL
        fi
    fi
}

# List a megaupload shared file folder URL
# $1: megaupload folder url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
megaupload_list() {
    eval "$(process_options megaupload "$MODULE_MEGAUPLOAD_LIST_OPTIONS" "$@")"

    local URL="$1"
    local XMLURL='http://www.megaupload.com/xml/folderfiles.php'
    local XML FOLDERID

    # check whether it looks like a folder link
    if ! match '\(?\|&\)f=' "$URL"; then
        log_error "This is not a folder"
        return $ERR_FATAL
    fi

    FOLDERID=$(echo "$URL" | parse '.' 'f=\([^=]\+\)') || return
    XML=$(curl "$XMLURL/?folderid=$FOLDERID") || return

    if match "<FILES></FILES>" "$XML"; then
        log_debug "empty folder"
        return 0
    fi

    echo "$XML" | parse_all_attr "<ROW" "url"
}
