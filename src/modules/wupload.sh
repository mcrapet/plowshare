#!/bin/bash
#
# wupload.com module
# Copyright (c) 2011-2012 Plowshare team
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

MODULE_WUPLOAD_REGEXP_URL="http://\(www\.\)\?wupload\(.com\?\)\?\.[a-z]\+/"

MODULE_WUPLOAD_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Premium account"
MODULE_WUPLOAD_DOWNLOAD_RESUME=no
MODULE_WUPLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_WUPLOAD_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_WUPLOAD_UPLOAD_REMOTE_SUPPORT=no

MODULE_WUPLOAD_LIST_OPTIONS=""

# Official API documentation: http://api.wupload.com/user
# Output a wupload.com file download URL
# $1: cookie file
# $2: wupload.com url
# stdout: real file download link
wupload_download() {
    eval "$(process_options wupload "$MODULE_WUPLOAD_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$2
    local LINK_ID DOMAIN START_HTML WAIT_HTML FILENAME FILE_URL MSG

    if match '/folder/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return $ERR_FATAL
    fi

    # Get Link Id. Possible URL pattern:
    # /file/12345                       => 12345
    # /file/12345/filename.zip          => 12345
    # /file/r54321/12345                => r54321-12345
    # /file/r54321/12345/filename.zip   => r54321-12345
    LINK_ID=$(echo "$URL" | parse '\/file\/' 'file\/\(\([a-z][0-9]\+\/\)\?\([0-9]\+\)\)') || return
    log_debug "Link ID: $LINK_ID"
    LINK_ID=${LINK_ID##*/}

    DOMAIN=$(curl 'http://api.wupload.com/utility?method=getWuploadDomainForCurrentIp') || return
    if match '"success"' "$DOMAIN"; then
        local SUB=$(echo "$DOMAIN" | parse 'response' 'se":"\([^"]*\)","')
        log_debug "Suitable domain for current ip: $SUB"
        URL="http://www${SUB}/file/$LINK_ID"
    else
        log_error "Can't get domain, try default"
        URL="http://www.wupload.com/file/$LINK_ID"
    fi

    # Try to get the download link using premium credentials (if $AUTH not null)
    if test "$AUTH"; then
        local BASE_URL="http://api.wupload.com"
        local USER="${AUTH%%:*}"
        local PASSWORD="${AUTH#*:}"

        if [ "$AUTH" = "$PASSWORD" ]; then
            PASSWORD=$(prompt_for_password) || return $ERR_LOGIN_FAILED
        fi

        # Not secure !
        JSON=$(curl "$BASE_URL/link?method=getDownloadLink&u=$USER&p=$PASSWORD&ids=$LINK_ID") || return

        # Login failed. Please check username or password.
        if match "Login failed" "$JSON"; then
            log_debug "login failed"
            return $ERR_LOGIN_FAILED
        fi

        # {"FSApi_Link":{"getDownloadLink":{"errors":{"FSApi_Auth_Exception":"User must be premium to use this feature."},"status":"failed"}}}
        if match 'must be premium' "$JSON"; then
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        log_debug "Successfully logged in as $USER member"

        URL=$(echo "$JSON" | parse 'url' '"url":"\([^"]*\)"') || return
        URL=${URL//[\\]/}
        FILENAME=$(echo "$JSON" | parse 'filename' '"filename":"\([^"]*\)"') || return

        echo "$URL"
        echo "$FILENAME"
        return 0
    fi

    if [ -s "$COOKIEFILE" ]; then
        START_HTML=$(curl -b "$COOKIEFILE" "$URL") || return
    else
        START_HTML=$(curl -c "$COOKIEFILE" "$URL") || return
    fi

    # Sorry, this file has been removed.
    if match 'class="deletedFile"' "$START_HTML"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    FILENAME=$(echo "$START_HTML" | parse '<title>' '>Get \(.*\) on ') || return

    # post request with empty Content-Length
    WAIT_HTML=$(curl -b "$COOKIEFILE" --data "" -H "X-Requested-With: XMLHttpRequest" \
            --referer "$URL" "${URL}/${LINK_ID}?start=1") || return

    # <div id="freeUserDelay" class="section CL3">
    if match 'freeUserDelay' "$WAIT_HTML"; then
        local WAIT_TIME FORM_TM FORM_TMHASH

        WAIT_TIME=$(echo "$WAIT_HTML" | parse 'var countDownDelay = ' 'countDownDelay = \([0-9]*\);')
        FORM_TM=$(echo "$WAIT_HTML" | parse_form_input_by_name 'tm')
        FORM_TMHASH=$(echo "$WAIT_HTML" | parse_form_input_by_name 'tm_hash')

        wait $((WAIT_TIME)) seconds || return

        WAIT_HTML=$(curl -b "$COOKIEFILE" --data "tm=${FORM_TM}&tm_hash=${FORM_TMHASH}" \
                -H "X-Requested-With: XMLHttpRequest" --referer "$URL" "${URL}?start=1")

    # <div id="downloadErrors" class="section CL3">
    # - You can only download 1 file at a time.
    elif match 'downloadErrors' "$WAIT_HTML"; then
        MSG=$(echo "$WAIT_HTML" | parse_quiet '<h3><span>' '<span>\([^<]*\)<')
        log_error "error: $MSG"
        return $ERR_FATAL

    # <div id="downloadLink" class="section CL3">
    # wupload is bugged when I requested several parallel download
    # link returned lead to an (302) error..
    elif match 'Download Ready' "$WAIT_HTML"; then
        FILE_URL=$(echo "$WAIT_HTML" | parse_attr '<a' 'href')
        log_debug "parallel download?"
        echo "$FILE_URL"
        echo "$FILENAME"
        return 0

    else
        log_debug "no wait delay, go on"
    fi

    # reCaptcha page
    if match 'Please enter the captcha below' "$WAIT_HTML"; then

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LdNWbsSAAAAAIMksu-X7f5VgYy8bZiiJzlP83Rl'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        HTMLPAGE=$(curl -b "$COOKIEFILE" --data \
            "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" \
            -H "X-Requested-With: XMLHttpRequest" --referer "$URL" \
            "${URL}?start=1") || return

        if match 'Wrong Code. Please try again.' "$HTMLPAGE"; then
            recaptcha_nack $ID
            log_error "Wrong captcha"
            return $ERR_CAPTCHA
        fi

        FILE_URL=$(echo "$HTMLPAGE" | parse_attr '\/download\/' 'href')
        if [ -n "$FILE_URL" ]; then
            recaptcha_ack $ID
            log_debug "correct captcha"

            echo "$FILE_URL"
            echo "$FILENAME"
            return 0
        fi

    # <div id="downloadErrors" class="section CL3">
    # - The file that you're trying to download is larger than 2048Mb.
    elif match 'downloadErrors' "$WAIT_HTML"; then
        MSG=$(echo "$WAIT_HTML" | parse_quiet '<h3><span>' '<span>\([^<]*\)<')
        log_error "error: $MSG"
        break
    fi

    log_error "Unknown state, give up!"
    return $ERR_FATAL
}

# Upload a file to wupload
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download link on wupload
wupload_upload() {
    eval "$(process_options wupload "$MODULE_WUPLOAD_UPLOAD_OPTIONS" "$@")"

    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://api.wupload.com/'
    local JSON URL LINK

    if test "$AUTH"; then
        local USER="${AUTH%%:*}"
        local PASSWORD="${AUTH#*:}"

        if [ "$AUTH" = "$PASSWORD" ]; then
            PASSWORD=$(prompt_for_password) || return $ERR_LOGIN_FAILED
        fi

        # Not secure !
        JSON=$(curl "$BASE_URL/upload?method=getUploadUrl&u=$USER&p=$PASSWORD") || return

        # Login failed. Please check username or password.
        if match "Login failed" "$JSON"; then
            log_debug "login failed"
            return $ERR_LOGIN_FAILED
        fi

        log_debug "Successfully logged in as $USER member"

        URL=$(echo "$JSON" | parse 'url' ':"\([^"]*json\)"') || return
        URL=${URL//[\\]/}
    else
        URL="http://web.eu.wupload.com/?callbackUrl=http://www.wupload.com/upload/done/:uploadProgressId&X-Progress-ID=upload_$$"
    fi

    # Upload one file per request
    JSON=$(curl_with_log -L -F "files[]=@$FILE;filename=$DESTFILE" "$URL") || return

    if ! match 'success' "$JSON"; then
        log_error "upload failed"
        return $ERR_FATAL
    fi

    if test "$AUTH"; then
        # {"FSApi_Upload":{"postFile":{"response":{"files":[{"name":"foobar.abc","url":"http:\/\/www.wupload.com...
        LINK=$(echo "$JSON" | parse 'url' ':"\([^"]*\)\",\"size')
        LINK=${LINK//[\\]/}
    else
        # data = [{"linkId":"F71602742","statusCode":0,"filename":"foobar.abc","statusMessage":"...
        LINK=$(echo "$JSON" | parse 'linkId' '"id":\([^,]*\)')
        LINK="http://www.wupload.com/file/$LINK"
    fi

    echo "$LINK"
    return 0
}

# List a wupload public folder URL
# $1: wupload folder url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
wupload_list() {
    eval "$(process_options wupload "$MODULE_WUPLOAD_LIST_OPTIONS" "$@")"

    local URL=$1
    local PAGE LINKS FILE_NAME FILE_URL

    test "$2" && log_debug "recursive flag is not supported"

    if ! match "${MODULE_WUPLOAD_REGEXP_URL}folder/" "$URL"; then
        log_error "This is not a folder"
        return $ERR_FATAL
    fi

    PAGE=$(curl -L "$URL") || return
    LINKS=$(echo "$PAGE" | grep "<a href=\"${MODULE_WUPLOAD_REGEXP_URL}file/")
    test "$LINKS" || return $ERR_LINK_DEAD

    # First pass: print file names (debug)
    while read LINE; do
        FILE_NAME=$(echo "$LINE" | parse_tag_quiet a)
        log_debug "$FILE_NAME"
    done <<< "$LINKS"

    # Second pass: print links (stdout)
    while read LINE; do
        FILE_URL=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$FILE_URL"
    done <<< "$LINKS"
}
