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
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_UPLOADED_TO_DOWNLOAD_RESUME=no
MODULE_UPLOADED_TO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_UPLOADED_TO_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account (mandatory)
DESCRIPTION,d:,description:,DESCRIPTION,Set file description"
MODULE_UPLOADED_TO_UPLOAD_REMOTE_SUPPORT=no

MODULE_UPLOADED_TO_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account (mandatory)"
MODULE_UPLOADED_TO_LIST_OPTIONS=""

# Static function. Proceed with login (free-membership or premium)
uploaded_to_login() {
    local AUTH="$1"
    local COOKIE_FILE="$2"
    local BASEURL="$3"

    local LOGIN_DATA LOGIN_RESULT NAME

    LOGIN_DATA='id=$USER&pw=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASEURL/io/login") || return

    # Note: "auth" entry is present in cookie too
    NAME=$(parse_cookie 'login' < "$COOKIE_FILE")
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
    eval "$(process_options uploaded_to "$MODULE_UPLOADED_TO_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local BASE_URL='http://uploaded.to'
    local URL FILE_ID HTML SLEEP FILE_NAME FILE_URL PAGE

    # uploaded.to redirects all possible urls of a file to the canonical one
    # ($URL result can have two lines before 'last_line')
    URL=$(curl -I -L "$2" | grep_http_header_location | last_line) || return
    if test -z "$URL"; then
        URL="$2"
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
        HTML=$(curl -c "$COOKIEFILE" "$URL") || return
    fi

    # extract the raw file id
    FILE_ID=$(echo "$URL" | parse 'uploaded' '\/file\/\([^\/]*\)')
    log_debug "file id=$FILE_ID"

    # set website language to english
    curl -b "$COOKIEFILE" "$BASE_URL/language/en" || return

    # check for files that need a password
    local ERROR=$(echo "$HTML" | parse_quiet "<h2>authentification</h2>")
    test "$ERROR" && return $ERR_LOGIN_FAILED

    # retrieve the waiting time
    SLEEP=$(echo "$HTML" | parse '<span>Current waiting period' \
        'period: <span>\([[:digit:]]\+\)<\/span>')
    test -z "$SLEEP" && log_error "can't get sleep time" && \
        log_debug "sleep time: $SLEEP" && return $ERR_FATAL

    wait $((SLEEP + 1)) seconds || return

    # from 'http://uploaded.to/js/download.js' - 'Recaptcha.create'
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6Lcqz78SAAAAAPgsTYF3UlGf2QFQCNuPMenuyHF3'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    local DATA="recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD"
    PAGE=$(curl -b "$COOKIEFILE" --referer "$URL" \
        --data "$DATA" "$BASE_URL/io/ticket/captcha/$FILE_ID") || return
    log_debug "Captcha response: $PAGE"

    # check for possible errors
    if match 'captcha' "$PAGE"; then
        recaptcha_nack $ID
        return $ERR_CAPTCHA
    elif match 'limit\|err' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    # {type:'download',url:'http://storXXXX.uploaded.to/dl/...'}
    elif match 'url' "$PAGE"; then
        FILE_URL=$(echo "$PAGE" | parse 'url' "url:'\(http.*\)'")
    else
        log_error "No match. Site update?"
        return $ERR_FATAL
    fi

    recaptcha_ack $ID
    log_debug "correct captcha"

    # retrieve real filename
    FILE_NAME=$(curl -I -b "$COOKIEFILE" "$FILE_URL" | grep_http_header_content_disposition)
    if [ -z "$FILE_NAME" ]; then
        # retrieve (truncated) filename
        FILE_NAME=$(echo "$HTML" | parse_quiet 'id="filename"' 'name">\([^<]*\)')
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
    eval "$(process_options uploaded_to "$MODULE_UPLOADED_TO_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local FILE="$2"
    local DESTFILE="$3"
    local BASE_URL='http://uploaded.to'

    local JS SERVER DATA FILE_ID AUTH_DATA ADMIN_CODE

    if [ -z "$AUTH" ]; then
        log_error "Anonymous users cannot upload files"
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    JS=$(curl "$BASE_URL/js/script.js") || return
    SERVER=$(echo "$JS" | parse '\/\/stor' "[[:space:]]'\([^']*\)") || return

    log_debug "uploadServer: $SERVER"

    uploaded_to_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return
    AUTH_DATA=$(parse_cookie 'login' < "$COOKIEFILE" | uri_decode)

    # TODO: Allow changing admin code (used for deletion)
    ADMIN_CODE="noyiva$$"

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
}

# Delete a file on uploaded.to
# $1: uploaded.to (download) link
uploaded_to_delete() {
    eval "$(process_options rapidshare "$MODULE_UPLOADED_TO_DELETE_OPTIONS" "$@")"

    local URL="$1"
    local BASE_URL='http://uploaded.to'
    local PAGE FILE_ID COOKIE_FILE

    if ! test "$AUTH"; then
        log_error "Anonymous users cannot delete files"
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    # extract the raw file id
    PAGE=$(curl -L "$URL") || return

    # <h1>Page not found<br /><small class="cL">Error: 404</small></h1>
    if match "Error: 404" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_ID=$(echo "$PAGE" | parse 'file\/' 'file\/\([^/"]\+\)') || return
    log_debug "file id=$FILE_ID"

    COOKIE_FILE=$(create_tempfile) || return
    uploaded_to_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/file/$FILE_ID/delete") || return
    rm -f "$COOKIE_FILE"

    # {succ:true}
    match 'true' "$PAGE" || return $ERR_FATAL
}

# List an uploaded.to shared file folder URL
# $1: uploaded.to url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
uploaded_to_list() {
    eval "$(process_options uploaded_to "$MODULE_UPLOADED_TO_LIST_OPTIONS" "$@")"

    local URL="$1"
    local PAGE LINKS FILE_NAME FILE_ID

    # check whether it looks like a folder link
    if ! match "${MODULE_UPLOADED_TO_REGEXP_URL}folder/" "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    PAGE=$(curl -L "$URL") || return
    LINKS=$(echo "$PAGE" | grep 'onclick="visit($(this))')
    test "$LINKS" || return $ERR_LINK_DEAD

    # First pass: print file names (debug)
    while read LINE; do
        FILE_NAME=$(echo "$LINE" | parse_tag_quiet a)
        log_debug "$FILE_NAME"
    done <<< "$LINKS"

    # Second pass: print links (stdout)
    while read LINE; do
        # This gives links: "file/$FILE_ID/from/folderid"
        #FILE_ID=$(echo "$LINE" | parse_attr '<a' 'href')

        FILE_ID=file/$(echo "$LINE" | parse '.' 'file\/\([^/]\+\)')
        echo "http://uploaded.to/$FILE_ID"
    done <<< "$LINKS"
}
