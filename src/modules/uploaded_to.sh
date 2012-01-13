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

MODULE_UPLOADED_TO_DOWNLOAD_OPTIONS=""
MODULE_UPLOADED_TO_DOWNLOAD_RESUME=no
MODULE_UPLOADED_TO_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_UPLOADED_TO_UPLOAD_OPTIONS=""
MODULE_UPLOADED_TO_LIST_OPTIONS=""

# Output an uploaded.to file download URL
# $1: cookie file
# $2: upload.to url
# stdout: real file download link
# Note: Anonymous download restriction: 1 file every 60 minutes.
uploaded_to_download() {
    eval "$(process_options uploaded_to "$MODULE_UPLOADED_TO_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local BASE_URL='http://uploaded.to'
    local URL FILE_ID HTML SLEEP FILE_NAME FILE_URL

    # uploaded.to redirects all possible urls of a file to the canonical one
    # (URL can have two lines)
    URL=$(curl -I -L "$2" | grep_http_header_location | last_line) || return
    if test -z "$URL"; then
        URL="$2"
    fi

    # recognize folders
    if match 'uploaded\.to/folder/' "$URL"; then
        log_error "This is a directory list"
        return $ERR_FATAL
    fi

    # file does not exist
    if match 'uploaded\.to/404' "$URL"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # extract the raw file id
    FILE_ID=$(echo "$URL" | parse 'uploaded' '\/file\/\([^\/]*\)')
    log_debug "file id=$FILE_ID"

    # set website language to english
    curl -c "$COOKIEFILE" "$BASE_URL/language/en" || return

    HTML=$(curl -c $COOKIEFILE "$URL")

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
    local PAGE=$(curl -b "$COOKIEFILE" --referer "$URL" \
        --data "$DATA" "$BASE_URL/io/ticket/captcha/$FILE_ID")
    log_debug "Captcha resonse: $PAGE"

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

    # retrieve (truncated) filename
    # Only 1 access to "final" URL is allowed, so we can't get complete name
    # using "Content-Disposition:"
    FILE_NAME=$(echo "$HTML" | parse_quiet 'id="filename"' 'name">\([^<]*\)')

    recaptcha_ack $ID
    log_debug "correct captcha"

    echo "$FILE_URL"
    test "$FILE_NAME" && echo "$FILE_NAME"
}

# Upload a file to uploaded.to
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: ul.to download link
uploaded_to_upload() {
    eval "$(process_options uploaded_to "$MODULE_UPLOADED_TO_UPLOAD_OPTIONS" "$@")"

    local FILE="$2"
    local DESTFILE="$3"

    local JS SERVER DATA

    JS=$(curl 'http://uploaded.to/js/script.js') || return
    SERVER=$(echo "$JS" | parse '\/\/stor' "[[:space:]]'\([^']*\)") || return

    log_debug "uploadServer: $SERVER"

    # TODO: Allow changing admin code (used for deletion)

    DATA=$(curl_with_log --user-agent 'Shockwave Flash' \
        -F "Filename=$DESTFILE" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        -F 'Upload=Submit Query' \
        "${SERVER}upload?admincode=noyiva") || return

    echo "http://ul.to/${DATA%%,*}"
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
        FILE_NAME=$(echo "$LINE" | parse_quiet 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILE_NAME"
    done <<< "$LINKS"

    # Second pass: print links (stdout)
    while read LINE; do
        #FILE_ID=$(echo "$LINE" | parse_attr '<a' 'href')
        FILE_ID=file/$(echo "$LINE" | parse '.' 'file\/\([^/]\+\)')
        echo "http://uploaded.to/$FILE_ID"
    done <<< "$LINKS"
}
