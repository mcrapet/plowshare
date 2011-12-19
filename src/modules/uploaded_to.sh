#!/bin/bash
#
# uploaded.to module
# Copyright (c) 2011 Krompo@speed.1s.fr
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
uploaded_to_download() {
    eval "$(process_options uploaded_to "$MODULE_UPLOADED_TO_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL FILE_ID HTML SLEEP FILE_NAME

    # uploaded.to redirects all possible urls of a file to the canonical one
    URL=$(curl -I "$2" | grep_http_header_location) || return
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

    local BASE_URL='http://uploaded.to'

    # extract the raw file id
    FILE_ID=$(echo "$URL" | parse 'uploaded' '\/file\/\([^\/]*\)')
    log_debug "file id=$FILE_ID"

    # set website language to english
    curl -c $COOKIEFILE "$BASE_URL/language/en" || return

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
    elif match 'url' "$PAGE"; then
        local FILE_URL=$(echo "$PAGE" | parse 'url' "url:'\(http.*\)'")
    else
        log_error "No match. Site update?"
        return $ERR_FATAL
    fi

    # retrieve real filename
    FILE_NAME=$(curl -I "$FILE_URL" | grep_http_header_content_disposition) || return

    recaptcha_ack $ID
    log_debug "correct captcha"

    echo "$FILE_URL"
    echo "$FILE_NAME"
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
    local URL="$1"

    # check whether it looks like a folder link
    if ! match "${MODULE_UPLOADED_TO_REGEXP_URL}folder/" "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    local PAGE=$(curl -L "$URL")

    if test -z "$PAGE"; then
        log_error "Cannot retrieve page"
        return $ERR_FATAL
    fi

    # First pass: print file names (debug)
    while read LINE; do
        local NAME=$(echo "$LINE" | parse_quiet '<h2><a href="file\/' \
          'onclick="visit($(this))">\([^<]*\)<\/a>')
        test $NAME && log_debug "$NAME"
    done <<< "$PAGE"

    # Second pass: print links (stdout)
    while read LINE; do
        local LINK=$(echo "$LINE" | parse_quiet '<h2><a href="file\/' \
          'href="\([^"]*\)"')
        test $LINK && echo "http://uploaded.to/$LINK"
    done <<< "$PAGE"

    return 0
}
