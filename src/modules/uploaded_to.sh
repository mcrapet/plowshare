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

    # uploaded.to redirects all possible urls of a file to the canonical one
    local URL=$(curl -I "$2" | grep_http_header_location)
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
        log_error "File not found"
        return $ERR_LINK_DEAD
    fi

    local BASE_URL='http://uploaded.to'

    # extract the raw file id
    local FILE_ID=$(echo "$URL" | parse 'uploaded' '\/file\/\([^\/]*\)')
    log_debug "file id=$FILE_ID"

    # set website language to english
    curl -c $COOKIEFILE "$BASE_URL/language/en"

    while retry_limit_not_reached || return; do
        local HTML=$(curl -c $COOKIEFILE "$URL")

        # check for files that need a password
        local ERROR=$(echo "$HTML" | parse_quiet "<h2>authentification</h2>")
        test "$ERROR" && return $ERR_LOGIN_FAILED

        # retrieve the waiting time
        local SLEEP=$(echo "$HTML" | parse '<span>Current waiting period' \
            'period: <span>\([[:digit:]]\+\)<\/span>')
        test -z "$SLEEP" && log_error "can't get sleep time" && \
            log_debug "sleep time: $SLEEP" && return $ERR_FATAL

        # from 'http://uploaded.to/js/download.js' - 'Recaptcha.create'
        local PUBKEY='6Lcqz78SAAAAAPgsTYF3UlGf2QFQCNuPMenuyHF3'
        local IMAGE_FILENAME=$(recaptcha_load_image $PUBKEY)

        if ! test "$IMAGE_FILENAME"; then
            log_error "reCaptcha error"
            return $ERR_FATAL
        fi

        local TRY=1
        while retry_limit_not_reached || return; do
            log_debug "reCaptcha manual entering (loop $TRY)"
            (( TRY++ ))

            local WORD=$(captcha_process "$IMAGE_FILENAME")

            rm -f $IMAGE_FILENAME

            test "$WORD" && break

            log_debug "empty, request another image"
            local IMAGE_FILENAME=$(recaptcha_reload_image $PUBKEY "$IMAGE_FILENAME")
        done

        # wait the designates time + 1 second to be safe
        wait $((SLEEP + 1)) seconds || return

        local CHALLENGE=$(recaptcha_get_challenge_from_image "$IMAGE_FILENAME")

        local DATA="recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD"
        local PAGE=$(curl -b "$COOKIEFILE" --referer "$URL" \
            --data "$DATA" "$BASE_URL/io/ticket/captcha/$FILE_ID")
        log_debug "Captcha resonse: $PAGE"

        # check for possible errors
        if match 'limit\|err' "$PAGE"; then
            return $ERR_LINK_TEMP_UNAVAILABLE
        elif match 'url' "$PAGE"; then
            local FILE_URL=$(echo "$PAGE" | parse 'url' "url:'\(http.*\)'")
            break
        else
            log_error "No match. Site update?"
            return $ERR_FATAL
        fi
    done

    # retrieve real filename
    local FILE_NAME=$(curl -I "$FILE_URL" | grep_http_header_content_disposition)

    echo $FILE_URL
    echo $FILE_NAME
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

# List a uploaded.to shared file folder URL
# $1: url
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
