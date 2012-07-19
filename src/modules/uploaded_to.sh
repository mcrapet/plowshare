#!/bin/bash
#
# uploaded.to module
# Copyright (c) 2011 Krompo@speed.1s.fr
# Copyright (c) 2012 Plowshare team
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

MODULE_UPLOADED_TO_REGEXP_URL="http://\(www\.\)\?\(uploaded\|ul\)\.to/"

MODULE_UPLOADED_TO_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_UPLOADED_TO_DOWNLOAD_RESUME=no
MODULE_UPLOADED_TO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_UPLOADED_TO_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)
DESCRIPTION,d,description,S=DESCRIPTION,Set file description"
MODULE_UPLOADED_TO_UPLOAD_REMOTE_SUPPORT=no

MODULE_UPLOADED_TO_DELETE_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)"
MODULE_UPLOADED_TO_LIST_OPTIONS=""

# Static function. Proceed with login (free-membership or premium)
uploaded_to_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASEURL=$3

    local LOGIN_DATA LOGIN_RESULT NAME

    LOGIN_DATA='id=$USER&pw=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASEURL/io/login") || return

    # Note: "auth" entry is present in cookie too
    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -n "$NAME" ]; then
        NAME=$(echo "$NAME" | uri_decode | cut -d'&' -f2)
        log_debug "Successfully logged in as ${NAME:3} member"
        return 0
    fi

    return $ERR_LOGIN_FAILED
}

# Output an uploaded.to file download URL
# $1: cookie file
# $2: upload.to url
# stdout: real file download link
# Note: Anonymous download restriction: 1 file every 60 minutes.
uploaded_to_download() {
    local COOKIEFILE=$1
    local BASE_URL='http://uploaded.to'
    local URL FILE_ID HTML SLEEP FILE_NAME FILE_URL PAGE

    # uploaded.to redirects all possible urls of a file to the canonical one
    # ($URL result can have two lines before 'last_line')
    URL=$(curl -I -L "$2" | grep_http_header_location_quiet | last_line) || return
    if test -z "$URL"; then
        URL=$2
    fi

    # recognize folders
    if match 'uploaded\.to/folder/' "$URL"; then
        log_error "This is a directory list"
        return $ERR_FATAL
    fi

    # Page not found
    # The requested file isn't available anymore!
    if match 'uploaded\.to/\(404\|410\)' "$URL"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    if [ -n "$AUTH" ]; then
        uploaded_to_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return

        # set website language to english
        log_debug "must change account preferred language to english"
        curl -b "$COOKIEFILE" "$BASE_URL/language/en" || return

        # save HTTP headers to detect "direct downloads" option
        HTML=$(curl -i -b "$COOKIEFILE" "$URL") || return

        # Premium user ?
        if ! match 'Choose your download method' "$HTML"; then
            FILE_URL=$(echo "$HTML" | grep_http_header_location)
            if [ -z "$FILE_URL" ]; then
                FILE_URL=$(echo "$HTML" | parse_attr 'stor' 'action') || return
            fi

            FILE_NAME=$(curl --head -b "$COOKIEFILE" "$FILE_URL" | \
                grep_http_header_content_disposition)

            # Non premium cannot resume downloads
            MODULE_UPLOADED_TO_DOWNLOAD_RESUME=yes

            echo "$FILE_URL"
            echo "$FILE_NAME"
            return 0
        fi
    else
        # set website language to english (currently default language)
        curl -c "$COOKIEFILE" "$BASE_URL/language/en" || return

        HTML=$(curl -b "$COOKIEFILE" "$URL") || return
    fi

    # extract the raw file id
    FILE_ID=$(echo "$URL" | parse 'uploaded' '/file/\([^/]*\)')
    log_debug "file id=$FILE_ID"

    # check for files that need a password (file owner never needs password,
    # so this comes after login)
    if match '<h2>Authentification</h2>' "$HTML"; then
        log_debug "File is password protected"
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD="$(prompt_for_password)" || return
        fi

        HTML=$(curl -b "$COOKIEFILE" -F "pw=$LINK_PASSWORD" "$URL") || return
        if match '<h2>Authentification</h2>' "$HTML"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        fi
    fi

    # Our service is currently unavailable in your country. We are sorry about that.
    if match '<h2>Not available</h2>' "$HTML"; then
        echo 600
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # retrieve the waiting time
    SLEEP=$(echo "$HTML" | parse '<span>Current waiting period' \
        'period: <span>\([[:digit:]]\+\)</span>')
    test -z "$SLEEP" && log_error "can't get sleep time" && \
        log_debug "sleep time: $SLEEP" && return $ERR_FATAL

    wait $((SLEEP + 1)) seconds || return

    PAGE=$(curl -b "$COOKIEFILE" --referer "$URL" \
        "$BASE_URL/io/ticket/captcha/$FILE_ID") || return
    log_debug "Ticket response: $PAGE"

    # check for possible errors
    if match 'captcha' "$PAGE"; then
        log_error 'Captchas reintroduced'
        return $ERR_CAPTCHA
    elif match 'limit\|err' "$PAGE"; then
        echo 600
        return $ERR_LINK_TEMP_UNAVAILABLE
    # {type:'download',url:'http://storXXXX.uploaded.to/dl/...'}
    elif match 'url' "$PAGE"; then
        FILE_URL=$(echo "$PAGE" | parse 'url' "url:'\(http.*\)'")
    else
        log_error "No match. Site update?"
        return $ERR_FATAL
    fi

    FILE_NAME=$(curl "$BASE_URL/file/$FILE_ID/status" | first_line) || return
    if [ -z "$FILE_NAME" ]; then
        # retrieve (truncated) filename
        # Only 1 access to "final" URL is allowed, so we can't get complete name
        # using "Content-Disposition:" header
        FILE_NAME=$(echo "$HTML" | parse_tag_quiet 'id="filename"' 'a' | replace '&hellip;' '.')
    fi

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to uploaded.to
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: ul.to download link
uploaded_to_upload() {
    local COOKIEFILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://uploaded.to'

    local JS SERVER DATA FILE_ID AUTH_DATA ADMIN_CODE

    test "$AUTH" || return $ERR_LINK_NEED_PERMISSIONS

    JS=$(curl "$BASE_URL/js/script.js") || return
    SERVER=$(echo "$JS" | parse '//stor' "[[:space:]]'\([^']*\)") || return

    log_debug "uploadServer: $SERVER"

    uploaded_to_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return
    AUTH_DATA=$(parse_cookie 'login' < "$COOKIEFILE" | uri_decode) || return

    # TODO: Allow changing admin code (used for deletion)
    ADMIN_CODE=$(random a 8)

    DATA=$(curl_with_log --user-agent 'Shockwave Flash' \
        -F "Filename=$DESTFILE" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        -F 'Upload=Submit Query' \
        "${SERVER}upload?admincode=${ADMIN_CODE}$AUTH_DATA") || return
    FILE_ID="${DATA%%,*}"

    if [ -n "$DESCRIPTION" ]; then
        if [ -n "$AUTH" ]; then
            DATA=$(curl -b "$COOKIEFILE" --referer "$BASE_URL/manage" \
            --form-string "description=$DESCRIPTION" \
            "$BASE_URL/file/$FILE_ID/edit/description") || return
            log_debug "description set to: $DATA"
        else
            log_error "Anonymous users cannot set description"
        fi
    fi

    echo "http://ul.to/$FILE_ID"
    echo
    echo "$ADMIN_CODE"
}

# Delete a file on uploaded.to
# $1: cookie file
# $2: uploaded.to (download) link
uploaded_to_delete() {
    local COOKIE_FILE=$1
    local URL=$2
    local BASE_URL='http://uploaded.to'
    local PAGE FILE_ID

    test "$AUTH" || return $ERR_LINK_NEED_PERMISSIONS

    # extract the raw file id
    PAGE=$(curl -L "$URL") || return

    # <h1>Page not found<br /><small class="cL">Error: 404</small></h1>
    if match "Error: 404" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_ID=$(echo "$PAGE" | parse 'file/' 'file/\([^/"]\+\)') || return
    log_debug "file id=$FILE_ID"

    uploaded_to_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/file/$FILE_ID/delete") || return

    # {succ:true}
    # Note: This is not JSON because succ is not quoted (")
    match 'true' "$PAGE" || return $ERR_FATAL
}

# List an uploaded.to shared file folder URL
# $1: uploaded.to url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
uploaded_to_list() {
    local URL=$1
    local PAGE LINKS NAMES

    # check whether it looks like a folder link
    if ! match "${MODULE_UPLOADED_TO_REGEXP_URL}folder/" "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    test "$2" && log_debug "recursive folder does not exist in depositfiles"

    PAGE=$(curl -L "$URL") || return

    LINKS=$(echo "$PAGE" | parse_all_attr 'tr id="' id)
    NAMES=$(echo "$PAGE" | parse_all_tag_quiet 'onclick="visit($(this))' a)

    test "$LINKS" || return $ERR_LINK_DEAD

    list_submit "$LINKS" "$NAMES" 'http://uploaded.to/file/' || return
}
