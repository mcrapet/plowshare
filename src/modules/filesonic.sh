#!/bin/bash
#
# filesonic.com module
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

MODULE_FILESONIC_REGEXP_URL="http://\(www\.\)\?filesonic\.[a-z]\+/"

MODULE_FILESONIC_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_FILESONIC_DOWNLOAD_RESUME=no
MODULE_FILESONIC_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_FILESONIC_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account (mandatory)"
MODULE_FILESONIC_UPLOAD_REMOTE_SUPPORT=no

MODULE_FILESONIC_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account (mandatory)"
MODULE_FILESONIC_LIST_OPTIONS=""

# Static function. Proceed with login (free-membership or premium)
filesonic_login() {
    local AUTH=$1
    local COOKIES=$2
    local BASEURL=$3

    LOGIN_DATA='email=$USER&password=$PASSWORD'
    LOGIN=$(post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" \
        "$BASEURL/user/login" "-H X-Requested-With:XMLHttpRequest -H Accept:application/json")

    if ! test "$LOGIN"; then
        log_debug "Login error"
        return $ERR_LOGIN_FAILED
    fi

    STATUS=$(echo "$LOGIN" | parse_quiet '"status":"[^"]*"' '"status":"\([^"]*\)"')
    if [ "$STATUS" != "success" ]; then
        log_debug "Login failed: $STATUS"
        return $ERR_LOGIN_FAILED
    fi

    ROLE=$(parse_cookie "role" < "$COOKIES")
    log_debug "Successfully logged in as $ROLE member"

    return 0
}

# Official API documentation: http://api.filesonic.com/link
# Output a filesonic.com file download URL
# $1: cookie file
# $2: filesonic url
# stdout: real file download link
filesonic_download() {
    eval "$(process_options filesonic "$MODULE_FILESONIC_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL="$2"
    local LINK_ID DOMAIN PAGE FILENAME ROLE HEADERS

    if match '/folder/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return $ERR_FATAL
    fi

    # Get Link Id. Possible URL pattern:
    # /file/12345                       => 12345
    # /file/12345/filename.zip          => 12345
    # /file/r54321/12345                => r54321-12345
    # /file/r54321/12345/filename.zip   => r54321-12345
    LINK_ID=$(echo "$URL" | parse '\/file\/' 'file\/\(\([a-z][0-9]\+\/\)\?\([[:alnum:]]\+\)\)') || return
    log_debug "Link ID: $LINK_ID"
    LINK_ID=${LINK_ID##*/}

    DOMAIN=$(curl 'http://api.filesonic.com/utility?method=getFilesonicDomainForCurrentIp') || return
    if match '"success"' "$DOMAIN"; then
        local SUB=$(echo "$DOMAIN" | parse 'response' 'se":"\([^"]*\)","')
        log_debug "Suitable domain for current ip: $SUB"
        URL="http://www${SUB}/file/$LINK_ID"
    else
        log_error "Can't get domain, try default"
        URL="http://www.filesonic.com/file/$LINK_ID"
    fi

    HEADERS=''
    if [ -s "$COOKIEFILE" ]; then
        PAGE=$(curl -i -b "$COOKIEFILE" "$URL") || return
        # premium cookie
        if matchi '^location' "$PAGE"; then
            HEADERS="$PAGE"
            PAGE=$(curl "$URL") || return
        fi
    else
        # obtain mainpage first (unauthenticated) to get filename
        PAGE=$(curl -c "$COOKIEFILE" "$URL") || return
    fi

    # do not obtain filename from "<span>Filename:" because it is shortened
    # with "..." if too long; instead, take it from title:
    # <script type="text/javascript">document.write('<title>&#68;&#111; ... ');</script>
    FILENAME=$(echo "$PAGE" | parse_quiet "<title>" "<title>\([^<]\+\)" | html_to_utf8)
    FILENAME=$(echo "$FILENAME" | parse_quiet '.' 'Download \(.*\) for free on F')

    # User account
    if test "$AUTH"; then
        local BASEURL=$(basename_url "$URL")
        filesonic_login "$AUTH" "$COOKIEFILE" "$BASEURL" || return

        ROLE=$(parse_cookie "role" < "$COOKIEFILE")
        if [ "$ROLE" != 'free' ]; then
            FILE_URL=$(curl -I -b "$COOKIEFILE" "$URL" | grep_http_header_location)
            if ! test "$FILE_URL"; then
                log_error "No link received (most likely premium account expired)"
                return $ERR_FATAL
            fi

            echo "$FILE_URL"
            test "$FILENAME" && echo "$FILENAME"

            return 0
        fi
    else
        ROLE=$(parse_cookie "role" < "$COOKIEFILE")
        if [ "$ROLE" != 'free' -a -n "$HEADERS" ]; then
            echo "$HEADERS" | grep_http_header_location
            test "$FILENAME" && echo "$FILENAME"

            return 0
        fi
    fi

    # The file has been deleted as per a copyright notification
    if match 'errorDoesNotExist' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Normal user
    PAGE=$(curl -b "$COOKIEFILE" -H "X-Requested-With: XMLHttpRequest" \
                --referer "$URL?start=1" --data "" "$URL?start=1") || return

    # This file is not a collaboration file and is too big to be downloaded by free users.
    if match '<div class="downloadSteps errorSize">' "$PAGE"; then
        log_error "You're trying to download file larger than 400MB (only premium users can)."
        return $ERR_LINK_NEED_PERMISSIONS

    # Free users may only download 1 file at a time.
    elif match 'download 1 file at a time' "$PAGE"; then
        log_error "No parallel download allowed"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # wait step
    if match 'countDownDelay' "$PAGE"; then
        SLEEP=$(echo "$PAGE" | parse_quiet 'var countDownDelay = ' 'countDownDelay = \([0-9]*\);')

        # for wait time > 5min. these values may not be present
        # it just means we need to try again so the following code is fine
        TM=$(echo "$PAGE" | parse_attr_quiet "name='tm'" "value")
        TM_HASH=$(echo "$PAGE" | parse_attr_quiet "name='tm_hash'" "value")

        if [ -z "$TM" -o -z "$TM_HASH" ]; then
            echo $SLEEP
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        wait $SLEEP seconds || return

        PAGE=$(curl -b "$COOKIEFILE" -H "X-Requested-With: XMLHttpRequest" \
                    --referer "$URL" --data "tm=$TM&tm_hash=$TM_HASH" "$URL?start=1") || return
    fi

    # captcha step
    if match 'Please Enter Captcha' "$PAGE"; then

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LdNWbsSAAAAAIMksu-X7f5VgYy8bZiiJzlP83Rl'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        DATA="recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD"
        PAGE=$(curl -b "$COOKIEFILE" -H "X-Requested-With: XMLHttpRequest" \
                    --referer "$URL" --data "$DATA" "$URL?start=1") || return

        if match 'Please Enter Captcha' "$PAGE"; then
            recaptcha_nack $ID
            log_error "Wrong captcha"
            return $ERR_CAPTCHA
        fi

        recaptcha_ack $ID
        log_debug "correct captcha"
    fi

    # download link
    if matchi 'start download now' "$PAGE"; then
        FILE_URL=$(echo "$PAGE" | parse_attr 'downloadLink' 'href')
        echo "$FILE_URL"
        test "$FILENAME" && echo "$FILENAME"
        return 0
    fi

    log_error "Unknown state, give up!"
    return $ERR_FATAL
}

# Upload a file to filesonic (requires an account)
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download link on filesonic
filesonic_upload() {
    eval "$(process_options filesonic "$MODULE_FILESONIC_UPLOAD_OPTIONS" "$@")"

    local FILE="$2"
    local DESTFILE="$3"
    local BASE_URL='http://api.filesonic.com/'
    local JSON URL LINK

    # This is based on wupload.
    # We don't use filesonic_login here.

    if [ -z "$AUTH" ]; then
        log_error "Anonymous users cannot upload files"
        return $ERR_LINK_NEED_PERMISSIONS
    fi

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

    # Upload one file per request
    JSON=$(curl_with_log -L \
        -F "folderId=0" \
        -F "files[]=@$FILE;filename=$DESTFILE" "$URL") || return

    if ! match 'success' "$JSON"; then
        log_error "upload failed"
        return $ERR_FATAL
    fi

    # {"FSApi_Upload":{"postFile":{"response":{"files":[{"name":"foobar.abc","url":"http:\/\/www.filesonic.com...
    LINK=$(echo "$JSON" | parse 'url' ':"\([^"]*\)\",\"size')
    LINK=${LINK//[\\]/}

    echo "$LINK"
    return 0
}

# Delete a file on filesonic (requires an account)
# $1: download link (must be a file that account uploaded)
filesonic_delete() {
    eval "$(process_options filesonic "$MODULE_FILESONIC_DELETE_OPTIONS" "$@")"

    local URL="$1"

    if ! test "$AUTH"; then
        log_error "Anonymous users cannot delete links."
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    local ID=$(echo "$URL" | parse_quiet '\/file\/' 'file\/\([^/]*\)')
    if ! test "$ID"; then
        log_error "Cannot parse URL to extract file id (mandatory)"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # update URL if there is a specific .ccTLD location from there
    URL=$(basename_url "$URL")
    LOCATION=$(curl -I "$URL" | grep_http_header_location)
    if test "$LOCATION"; then
        URL=$(basename_url "$LOCATION")
    fi

    COOKIES=$(create_tempfile)

    # Attempt to authenticate
    filesonic_login "$AUTH" "$COOKIES" "$URL" || {
        rm -f "$COOKIES"
        return $ERR_FATAL
    }

    # Delete file, identifier is "F"+ID
    DELETE=$(curl -b "$COOKIES" -H "Accept: application/json" \
                -H "X-Requested-With: XMLHttpRequest" \
                --referer "$URL/filesystem/browse" \
                --data "files%5B%5D=F$ID" \
                "$URL/filesystem/delete")

    rm -f "$COOKIES"

    if ! test "$DELETE"; then
        log_debug "Delete error"
        return $ERR_FATAL
    elif match 'Item not found' "$DELETE"; then
        return $ERR_LINK_DEAD
    fi

    STATUS=$(echo "$DELETE" | parse_quiet '"status":"[^"]*"' '"status":"\([^"]*\)"')
    if [ "$STATUS" != "success" ]; then
        log_debug "Delete failed: $STATUS"
        return $ERR_FATAL
    fi

    return 0
}

# List a filesonic public folder URL
# $1: filesonic url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
filesonic_list() {
    local URL="$1"
    local PAGE LINKS FILE_NAME FILE_URL

    if ! match "${MODULE_FILESONIC_REGEXP_URL}folder/" "$URL"; then
        log_error "This is not a folder"
        return $ERR_FATAL
    fi

    test "$2" && log_debug "recursive flag is not supported"

    PAGE=$(curl -L "$URL") || return

    # Error 9001: Folder do not exist
    # The requested folder do not exist or was deleted by the owner.
    if match 'Error 9001:' "$PAGE"; then
        log_error "Folder does not exist"
        return $ERR_LINK_DEAD
    fi

    LINKS=$(echo "$PAGE" | grep "<a href=\"${MODULE_FILESONIC_REGEXP_URL}file")
    test "$LINKS" || return $ERR_LINK_DEAD

    # First pass: print file names (debug)
    while read LINE; do
        FILE_NAME=$(echo "$LINE" | parse_quiet 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILE_NAME"
    done <<< "$LINKS"

    # Second pass: print links (stdout)
    while read LINE; do
        FILE_URL=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$FILE_URL"
    done <<< "$LINKS"
}
