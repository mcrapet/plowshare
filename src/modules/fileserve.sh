#!/bin/bash
#
# fileserve.com module
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

MODULE_FILESERVE_REGEXP_URL="http://\(www\.\)\?fileserve\.com/"
MODULE_FILESERVE_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Premium account"
MODULE_FILESERVE_DOWNLOAD_CONTINUE=no
MODULE_FILESERVE_LIST_OPTIONS=""

# Output an fileserve.com file download URL (anonymous)
# $1: fileserve url string
# stdout: real file download link
#
# Note: Extra HTTP header "X-Requested-With: XMLHTTPRequested" is not required.
fileserve_download() {
    eval "$(process_options fileserve "$MODULE_FILESERVE_DOWNLOAD_OPTIONS" "$@")"

    # URL must be well formed (issue #280)
    local ID=$(echo "$1" | parse_quiet '\/file\/' 'file\/\([^/]*\)')
    if [ -z "$ID" ]; then
        log_debug "Cannot parse URL to extract file id, try anyway"
        URL=$1
    else
        URL="http://www.fileserve.com/file/$ID"
    fi

    COOKIES=$(create_tempfile)

    if [ -n "$AUTH" ]; then
        LOGIN_DATA='loginUserName=$USER&loginUserPassword=$PASSWORD&loginFormSubmit=Login'
        post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" "http://www.fileserve.com/login.php" >/dev/null || {
            rm -f $COOKIES
            return 1
        }

        FILE_URL=$(curl -i -b $COOKIES "$URL" | grep_http_header_location)
        rm -f $COOKIES

        test -z "$FILE_URL" && return 1
        test "$CHECK_LINK" && return 255

        echo "$FILE_URL"
        return 0
    fi

    # Arbitrary wait (local variables)
    STOP_FLOODING=360

    while retry_limit_not_reached || return 3; do
        MAINPAGE=$(curl -c $COOKIES "$URL") || return 1

        # "The file could not be found. Please check the download link."
        if match 'File not available' "$MAINPAGE"; then
            log_debug "File not found"
            rm -f $COOKIES
            return 254
        fi

        if test "$CHECK_LINK"; then
            rm -f $COOKIES
            return 255
        fi

        # Should return {"success":"showCaptcha"}
        JSON1=$(curl -b $COOKIES --referer "$URL" --data "checkDownload=check" "$URL") || return 1

        if match 'waitTime' "$JSON1"; then
            if test "$NOARBITRARYWAIT"; then
                log_debug "File temporarily unavailable"
                rm -f $COOKIES
                return 253
            fi

            log_notice "too many captcha failures, you must wait"
            wait $STOP_FLOODING seconds || return 2
            continue

        elif match 'timeLimit' "$JSON1"; then
            log_error "time limit, you must wait"
            if test "$NOARBITRARYWAIT"; then
                rm -f $COOKIES
                return 1
            fi

            wait $STOP_FLOODING seconds || return 2
            continue

        elif ! match 'success' "$JSON1"; then
            log_error "unexpected error, site update?"
            rm -f $COOKIES
            return 1
        fi

        break
    done

    local PUBKEY='6LdSvrkSAAAAAOIwNj-IY-Q-p90hQrLinRIpZBPi'
    IMAGE_FILENAME=$(recaptcha_load_image $PUBKEY)

    if [ -z "$IMAGE_FILENAME" ]; then
        log_error "reCaptcha error"
        rm -f $COOKIES
        return 1
    fi

    TRY=1
    while retry_limit_not_reached || return 3; do
        log_debug "reCaptcha manual entering (loop $TRY)"
        (( TRY++ ))

        WORD=$(recaptcha_display_and_prompt "$IMAGE_FILENAME")

        rm -f $IMAGE_FILENAME

        [ -n "$WORD" ] && break

        log_debug "empty, request another image"
        IMAGE_FILENAME=$(recaptcha_reload_image $PUBKEY "$IMAGE_FILENAME")
    done

    SHORT=$(basename_file "$URL")
    CHALLENGE=$(recaptcha_get_challenge_from_image "$IMAGE_FILENAME")

    # Should return {"success":1}
    JSON2=$(curl -b $COOKIES --referer "$URL" --data \
      "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD&recaptcha_shortencode_field=$SHORT" \
      "http://www.fileserve.com/checkReCaptcha.php") || return 1

    local ret=$(echo "$JSON2" | parse_quiet 'success' 'success"\?[[:space:]]\?:[[:space:]]\?\([[:digit:]]*\)')
    if [ "$ret" != "1" ] ; then
        log_error "wrong captcha"
        rm -f $COOKIES
        return 1
    fi

    log_debug "correct captcha"
    MSG1=$(curl -b $COOKIES --referer "$URL" --data "downloadLink=wait" "$URL") || return 1
    if match 'fail404' "$MSG1"; then
        log_error "unexpected result"
        rm -f $COOKIES
        return 1
    fi

    WAIT_TIME=$(echo "$MSG1" | cut -c4-)
    wait $((WAIT_TIME + 1)) seconds || return 2
    MSG2=$(curl -b $COOKIES --referer "$URL" --data "downloadLink=show" "$URL") || return 1

    FILE_URL=$(curl -i -b $COOKIES --referer "$URL" --data "download=normal" "$URL" | grep_http_header_location) || return 1

    rm -f $COOKIES
    echo "$FILE_URL"
}

# List a fileserve public folder URL
# $1: fileserve url
# stdout: list of links
fileserve_list() {
    set -e
    eval "$(process_options fileserve "$MODULE_FILESERVE_LIST_OPTIONS" "$@")"
    URL=$1

    if ! match 'fileserve\.com\/list\/' "$URL"; then
        log_error "This is not a directory list"
        return 1
    fi

    PAGE=$(curl "$URL" | grep '<a href="/file/')

    if test -z "$PAGE"; then
        log_error "Wrong directory list link"
        return 1
    fi

    # First pass: print file names (debug)
    echo "$PAGE" | while read LINE; do
        FILENAME=$(echo "$LINE" | parse 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILENAME"
    done

    # Second pass: print links (stdout)
    echo "$PAGE" | while read LINE; do
        LINK=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "http://www.fileserve.com$LINK"
    done

    return 0
}
