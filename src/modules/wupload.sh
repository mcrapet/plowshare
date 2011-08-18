#!/bin/bash
#
# wupload.com module
# Copyright (c) 2011 Plowshare team
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

MODULE_WUPLOAD_REGEXP_URL="http://\(www\.\)\?wupload\.com/"

MODULE_WUPLOAD_DOWNLOAD_OPTIONS=""
MODULE_WUPLOAD_DOWNLOAD_RESUME=no
MODULE_WUPLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_WUPLOAD_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or premium account"
MODULE_WUPLOAD_LIST_OPTIONS=""

# Output an wupload.com file download URL
# $1: cookie file
# $2: wupload.com url
# stdout: real file download link
wupload_download() {
    eval "$(process_options wupload "$MODULE_WUPLOAD_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL="$2"

    if match 'wupload\.com\/folder\/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return $ERR_FATAL
    fi

    local BASE_URL='http://www.wupload.com'
    local FILE_ID=$(echo "$URL" | parse_quiet '\/file\/' 'file\/\([^/]*\)')
    local START_HTML WAIT_HTML

    while retry_limit_not_reached || return; do
        START_HTML=$(curl -c "$COOKIEFILE" "$URL") || return

        # Sorry! This file has been deleted.
        if match 'This file has been deleted' "$START_HTML"; then
            log_debug "File not found"
            return $ERR_LINK_DEAD
        fi

        test "$CHECK_LINK" && return 0

        local FILENAME=$(echo "$START_HTML" | parse_quiet "<title>" ">Get \(.*\) on ")

        # post request with empty Content-Length
        WAIT_HTML=$(curl -b "$COOKIEFILE" --data "" -H "X-Requested-With: XMLHttpRequest" \
                --referer "$URL" "${BASE_URL}/file/${FILE_ID}/${FILE_ID}?start=1") || return

        # <div id="freeUserDelay" class="section CL3">
        if match 'freeUserDelay' "$WAIT_HTML"; then
            local SLEEP=$(echo "$WAIT_HTML" | parse_quiet 'var countDownDelay = ' 'countDownDelay = \([0-9]*\);')
            local form_tm=$(echo "$WAIT_HTML" | parse_form_input_by_name 'tm')
            local form_tmhash=$(echo "$WAIT_HTML" | parse_form_input_by_name 'tm_hash')

            wait $((SLEEP)) seconds || return

            WAIT_HTML=$(curl -b "$COOKIEFILE" --data "tm=${form_tm}&tm_hash=${form_tmhash}" \
                    -H "X-Requested-With: XMLHttpRequest" --referer "$URL" "${URL}?start=1")

        # <div id="downloadErrors" class="section CL3">
        # - You can only download 1 file at a time.
        elif match "downloadErrors" "$WAIT_HTML"; then
            local MSG=$(echo "$WAIT_HTML" | parse_quiet '<h3><span>' '<span>\([^<]*\)<')
            log_error "error: $MSG"
            break

        # <div id="downloadLink" class="section CL3">
        # wupload is bugged when I requested several parallel download
        # link returned lead to an (302) error..
        elif match 'Download Ready' "$WAIT_HTML"; then
            local FILE_URL=$(echo "$WAIT_HTML" | parse_attr '<a' 'href')
            log_debug "parallel download?"
            echo "$FILE_URL"
            test "$FILENAME" && echo "$FILENAME"
            return 0

        else
            log_debug "no wait delay, go on"
        fi

        # reCaptcha page
        if match 'Please enter the captcha below' "$WAIT_HTML"; then
            local PUBKEY='6LdNWbsSAAAAAIMksu-X7f5VgYy8bZiiJzlP83Rl'
            local IMAGE_FILENAME=$(recaptcha_load_image $PUBKEY)

            if [ -n "$IMAGE_FILENAME" ]; then
                local TRY=1

                while retry_limit_not_reached || return; do
                    log_debug "reCaptcha manual entering (loop $TRY)"
                    (( TRY++ ))

                    WORD=$(recaptcha_display_and_prompt "$IMAGE_FILENAME")

                    rm -f $IMAGE_FILENAME

                    [ -n "$WORD" ] && break

                    log_debug "empty, request another image"
                    IMAGE_FILENAME=$(recaptcha_reload_image $PUBKEY "$IMAGE_FILENAME")
                done

                CHALLENGE=$(recaptcha_get_challenge_from_image "$IMAGE_FILENAME")
                HTMLPAGE=$(curl -b "$COOKIEFILE" --data \
                    "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" \
                    -H "X-Requested-With: XMLHttpRequest" --referer "$URL" \
                    "${URL}?start=1") || return 1

                if match 'Wrong Code. Please try again.' "$HTMLPAGE"; then
                    log_debug "wrong captcha"
                    break
                fi

                local FILE_URL=$(echo "$HTMLPAGE" | parse_attr_quiet '\/download\/' 'href')
                if [ -n "$FILE_URL" ]; then
                    log_debug "correct captcha"
                    echo "$FILE_URL"
                    test "$FILENAME" && echo "$FILENAME"
                    return 0
                fi
            fi

            log_debug "reCaptcha error"
            return $ERR_CAPTCHA

        else
            log_error "Unknown state, give up!"
            break
        fi

    done
    return $ERR_FATAL
}

# Upload a file to wupload using wupload api - http://api.wupload.com/user
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3 (optional): alternate remote filename
# stdout: download link on wupload
wupload_upload() {
    eval "$(process_options wupload "$MODULE_WUPLOAD_UPLOAD_OPTIONS" "$@")"

    local FILE="$2"
    local DESTFILE=${3:-$FILE}
    local BASE_URL="http://api.wupload.com/"

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
        URL="http://s50.wupload.com/?callbackUrl=http://www.wupload.com/upload/done/:uploadProgressId&X-Progress-ID=upload_$$"
    fi

    # Upload one file per request
    JSON=$(curl_with_log -L -F "files[]=@$FILE;filename=$(basename_file "$DESTFILE")" "$URL") || return

    if ! match "success" "$JSON"; then
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
# $1: wupload url
# stdout: list of links
wupload_list() {
    local URL="$1"

    if ! match "${MODULE_WUPLOAD_REGEXP_URL}folder\/" "$URL"; then
        log_error "This is not a folder"
        return $ERR_FATAL
    fi

    PAGE=$(curl -L "$URL" | grep "<a href=\"${MODULE_WUPLOAD_REGEXP_URL}file/")

    if ! test "$PAGE"; then
        log_error "Wrong folder link (no download link detected)"
        return $ERR_FATAL
    fi

    # First pass: print file names (debug)
    while read LINE; do
        FILENAME=$(echo "$LINE" | parse_quiet 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILENAME"
    done <<< "$PAGE"

    # Second pass: print links (stdout)
    while read LINE; do
        LINK=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$LINK"
    done <<< "$PAGE"

    return 0
}
