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
AUTH,a:,auth:,USER:PASSWORD,Free or Premium account"
MODULE_FILESERVE_DOWNLOAD_RESUME=no
MODULE_FILESERVE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_FILESERVE_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Free or Premium account"
MODULE_FILESERVE_LIST_OPTIONS=""

# Static function for proceeding login
fileserve_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASEURL=$3

    LOGIN_DATA='loginUserName=$USER&loginUserPassword=$PASSWORD&loginFormSubmit=Login'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASEURL/login.php")

    STATUS=$(echo "$LOGIN_RESULT" | parse_quiet 'fail_info">' '">\([^<]*\)')
    if [ -n "$STATUS" ]; then
        log_debug "Login failed: $STATUS"
        return 1
    fi

    NAME=$(curl -b "$COOKIE_FILE" "$BASEURL/dashboard.php" | \
        parse 'Welcome ' '<strong>\([^<]*\)')
    log_notice "Successfully logged in as $NAME member"
    return 0
}

# Output an fileserve.com file download URL (anonymous)
# $1: cookie file
# $2: fileserve.com url
# stdout: real file download link
#
# Note: Extra HTTP header "X-Requested-With: XMLHTTPRequested" is not required.
fileserve_download() {
    eval "$(process_options fileserve "$MODULE_FILESERVE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"

    # URL must be well formed (issue #280)
    local ID=$(echo "$2" | parse_quiet '\/file\/' 'file\/\([^/]*\)')
    if [ -z "$ID" ]; then
        log_debug "Cannot parse URL to extract file id, try anyway"
        local URL="$2"
    else
        local URL="http://www.fileserve.com/file/$ID"
    fi

    if [ -n "$AUTH" ]; then
        LOGIN_DATA='loginUserName=$USER&loginUserPassword=$PASSWORD&loginFormSubmit=Login'
        LOGIN_RESULT=$(post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" "http://www.fileserve.com/login.php") || return 1

        # Check account type
        if ! match '<h3>Free' "$LOGIN_RESULT"; then
            FILE_URL=$(curl -i -b $COOKIEFILE "$URL" | grep_http_header_location)

            test -z "$FILE_URL" && return 1
            test "$CHECK_LINK" && return 0

            # Non premium cannot resume downloads
            MODULE_FILESERVE_DOWNLOAD_RESUME=yes

            echo "$FILE_URL"
            return 0
        fi
    fi

    # Arbitrary wait (local variables)
    STOP_FLOODING=360

    while retry_limit_not_reached || return 3; do
        if [ -s $COOKIEFILE ]; then
            MAINPAGE=$(curl -b $COOKIEFILE "$URL") || return 1
        else
            MAINPAGE=$(curl -c $COOKIEFILE "$URL") || return 1
        fi

        # "The file could not be found. Please check the download link."
        if match 'File not available' "$MAINPAGE"; then
            log_debug "File not found"
            return 254
        fi

        test "$CHECK_LINK" && return 0

        # Should return {"success":"showCaptcha"}
        JSON1=$(curl -b $COOKIEFILE --referer "$URL" --data "checkDownload=check" "$URL") || return 1

        if match 'waitTime' "$JSON1"; then
            no_arbitrary_wait || return 253
            log_debug "too many captcha failures"
            wait $STOP_FLOODING seconds || return 2
            continue

        elif match 'timeLimit' "$JSON1"; then
            no_arbitrary_wait || return 253
            log_debug "time limit, you must wait"
            wait $STOP_FLOODING seconds || return 2
            continue

        elif ! match 'success' "$JSON1"; then
            log_error "unexpected error, site update?"
            return 1
        fi

        break
    done

    local PUBKEY='6LdSvrkSAAAAAOIwNj-IY-Q-p90hQrLinRIpZBPi'
    IMAGE_FILENAME=$(recaptcha_load_image $PUBKEY)

    if [ -z "$IMAGE_FILENAME" ]; then
        log_error "reCaptcha error"
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
    JSON2=$(curl -b $COOKIEFILE --referer "$URL" --data \
      "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD&recaptcha_shortencode_field=$SHORT" \
      "http://www.fileserve.com/checkReCaptcha.php") || return 1

    local ret=$(echo "$JSON2" | parse_quiet 'success' 'success"\?[[:space:]]\?:[[:space:]]\?\([[:digit:]]*\)')
    if [ "$ret" != "1" ] ; then
        log_error "wrong captcha"
        return 1
    fi

    log_debug "correct captcha"
    MSG1=$(curl -b $COOKIEFILE --referer "$URL" --data "downloadLink=wait" "$URL") || return 1
    if match 'fail404' "$MSG1"; then
        log_error "unexpected result"
        return 1
    fi

    WAIT_TIME=$(echo "$MSG1" | cut -b4-)
    wait $((WAIT_TIME + 1)) seconds || return 2
    MSG2=$(curl -b $COOKIEFILE --referer "$URL" --data "downloadLink=show" "$URL") || return 1

    FILE_URL=$(curl -i -b $COOKIEFILE --referer "$URL" --data "download=normal" "$URL" | grep_http_header_location) || return 1

    echo "$FILE_URL"
}

# Upload a file to fileserve (anonymous only for now)
# $1: file name to upload
# $2: upload as file name (optional, defaults to $1)
# stdout: download link on fileserve
fileserve_upload() {
    eval "$(process_options fileserve "$MODULE_FILESERVE_UPLOAD_OPTIONS" "$@")"

    local FILE=$1
    local DESTFILE=${2:-$FILE}
    local BASEURL="http://www.fileserve.com"

    # Attempt to authenticate
    if test "$AUTH"; then
        COOKIES=$(create_tempfile)
        fileserve_login "$AUTH" "$COOKIES" "$BASEURL" || {
            rm -f "$COOKIES"
            return 1
        }
        PAGE=$(curl -b "$COOKIES" "$BASEURL/upload-file.php")
        rm -f "$COOKIES"
    else
        PAGE=$(curl "$BASEURL/upload-file.php")
    fi

    # Send (post) form
    local FORM_HTML=$(grep_form_by_id "$PAGE" 'uploadForm')
    local form_url=$(echo "$FORM_HTML" | parse_form_action)

    local form_affiliateId=$(echo "$FORM_HTML" | parse_form_input_by_name 'affiliateId')
    local form_subAffiliateId=$(echo "$FORM_HTML" | parse_form_input_by_name 'subAffiliateId')
    local form_landingId=$(echo "$FORM_HTML" | parse_form_input_by_name 'landingId')
    local form_serverId=$(echo "$FORM_HTML" | parse_form_input_by_name 'serverId')
    local form_userId=$(echo "$FORM_HTML" | parse_form_input_by_name 'userId')
    local form_uploadSessionId=$(echo "$FORM_HTML" | parse_form_input_by_name 'uploadSessionId')
    local form_uploadHostURL=$(echo "$FORM_HTML" | parse_form_input_by_name 'uploadHostURL')

    # Get sessionId
    JSON=$(curl "$BASEURL/upload-track.php" | parse 'sessionId' ':"\([^"]*\)')
    log_debug "sessionId: $JSON"

    if [ -z "$form_userId" ]; then
        form_userId=6616385
    fi
    log_debug "userId: $form_userId"

    if [ -z "$form_uploadSessionId" ]; then
        form_uploadSessionId=$JSON
    fi

    # Sending HTTP 1.0 post because lighttpd/1.4.25 doesn't support
    # Except keyword (see HTTP error code 417)
    PAGE=$(curl --http1.0 -F "affiliateId=${form_affiliateId}" \
            -F "subAffiliateId=${form_subAffiliateId}" \
            -F "landingId=${form_landingId}" \
            -F "file=@$FILE;filename=$(basename_file "$DESTFILE")" \
            -F "serverId=${form_serverId}" \
            -F "userId=${form_userId}" \
            -F "uploadSessionId=${form_uploadSessionId}" \
            -F "uploadHostURL=${form_uploadHostURL}" \
            "${form_url}$JSON") || return 1

    PAGE=$(curl --data "uploadSessionId[]=$form_uploadSessionId" \
            "$BASEURL/upload-result.php")

    LINK=$(echo "$PAGE" | parse 'com\/file\/' 'readonly >\(.*\)')

    if [ -z "$LINK" ]; then
        log_error "upload failed or site updated?"
        return 1
    fi

    LINK_DEL=$(echo "$PAGE" | parse_quiet '\/delete\/' 'readonly >\(.*\)')

    if [ -z "$LINK_DEL" ]; then
        echo "$LINK"
    else
        echo "$LINK ($LINK_DEL)"
    fi

    return 0
}

# List a fileserve public folder URL
# $1: fileserve url
# stdout: list of links
fileserve_list() {
    URL="$1"

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
    while read LINE; do
        FILENAME=$(echo "$LINE" | parse 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILENAME"
    done <<< "$PAGE"

    # Second pass: print links (stdout)
    while read LINE; do
        LINK=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "http://www.fileserve.com$LINK"
    done <<< "$PAGE"

    return 0
}
