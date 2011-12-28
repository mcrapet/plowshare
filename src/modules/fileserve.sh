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
MODULE_FILESERVE_DELETE_OPTIONS="
CONFIRM_CODE,,code:,CODE,Confirmation code for premium link deletion"

# Static function. Proceed with login (free-membership or premium)
fileserve_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASEURL=$3

    local LOGIN_DATA LOGIN_RESULT STATUS NAME

    LOGIN_DATA='loginUserName=$USER&loginUserPassword=$PASSWORD&loginFormSubmit=Login'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASEURL/login.php") || return

    STATUS=$(echo "$LOGIN_RESULT" | parse_quiet 'fail_info">' '">\([^<]*\)')
    if [ -n "$STATUS" ]; then
        log_debug "Login failed: $STATUS"
        return $ERR_LOGIN_FAILED
    fi

    LOGIN_RESULT=$(curl -b "$COOKIE_FILE" "$BASEURL/dashboard.php") || return
    NAME=$(echo "$LOGIN_RESULT" | parse_line_after 'Welcome' \
            '<strong>\([^<]*\)') || return $ERR_LOGIN_FAILED

    log_debug "Successfully logged in as $NAME member"

    echo "$LOGIN_RESULT"
    return 0
}

# Output a fileserve.com file download URL
# $1: cookie file
# $2: fileserve.com url
# stdout: real file download link
#
# Note: Extra HTTP header "X-Requested-With: XMLHTTPRequested" is not required.
fileserve_download() {
    eval "$(process_options fileserve "$MODULE_FILESERVE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local BASEURL='http://www.fileserve.com'
    local ID URL LOGIN_RESULT FILE_URL MAINPAGE JSON1 JSON2 MSG1 MSG2 MSG3 WAIT_TIME

    # URL must be well formed (issue #280)
    ID=$(echo "$2" | parse_quiet '\/file\/' 'file\/\([^/]*\)')
    if [ -z "$ID" ]; then
        log_debug "Cannot parse URL to extract file id, try anyway"
        URL="$2"
    else
        URL="http://www.fileserve.com/file/$ID"
    fi

    if [ -n "$AUTH" ]; then
        LOGIN_RESULT=$(fileserve_login "$AUTH" "$COOKIEFILE" "$BASEURL") || return

        # Check account type
        if match '<h3>Premium ' "$LOGIN_RESULT"; then
            # Works for both "Direct Download" enabled/disabled
            MAINPAGE=$(curl -i -b "$COOKIEFILE" --data "download=premium" "$URL") || return

            if match 'File not available' "$MAINPAGE"; then
                return $ERR_LINK_DEAD
            fi

            FILE_URL=$(echo "$MAINPAGE" | grep_http_header_location)
            test -z "$FILE_URL" && return $ERR_FATAL

            if [ "${FILE_URL:0:1}" = '/' ]; then
                MSG1=$(curl -L -b "$COOKIEFILE" "$URL" | parse_attr_quiet '0; URL' 'CONTENT')
                log_error "fileserve internal error (${BASEURL}${MSG1:7})"
                return $ERR_FATAL
            fi

            test "$CHECK_LINK" && return 0

            # Non premium cannot resume downloads
            MODULE_FILESERVE_DOWNLOAD_RESUME=yes

            echo "$FILE_URL"
            return 0
        fi

        log_debug "free account type"
    fi

    # Arbitrary wait (local variables)
    STOP_FLOODING=360

    if [ -s "$COOKIEFILE" ]; then
        MAINPAGE=$(curl -b "$COOKIEFILE" "$URL") || return

        # Provided PHPSESSID is a premium account ?
        # Returned data 4 bytes: UTF-8 BOM + \n
        if ! match 'html' "$MAINPAGE"; then
            FILE_URL=$(curl -i -b "$COOKIEFILE" "$URL" | grep_http_header_location) || return

            if [ -z "$FILE_URL" ]; then
                log_debug "invalid cookie?"
                return $ERR_FATAL
            fi

            test "$CHECK_LINK" && return 0
            MODULE_FILESERVE_DOWNLOAD_RESUME=yes
            echo "$FILE_URL"
            return 0
        fi
    else
        MAINPAGE=$(curl -c "$COOKIEFILE" "$URL") || return
    fi

    # "The file could not be found. Please check the download link."
    if match 'File not available' "$MAINPAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Should return {"success":"showCaptcha"}
    JSON1=$(curl -b "$COOKIEFILE" --referer "$URL" --data "checkDownload=check" "$URL") || return

    if match 'waitTime' "$JSON1"; then
        log_debug "too many captcha failures"
        echo $STOP_FLOODING
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match 'timeLimit' "$JSON1"; then
        log_debug "time limit, you must wait"
        echo $STOP_FLOODING
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match 'parallelDownload' "$JSON1"; then
        log_debug "your IP is already downloading, you must wait"
        echo $STOP_FLOODING
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif ! match 'success' "$JSON1"; then
        log_error "unexpected error, site update?"
        return $ERR_FATAL
    fi

    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6LdSvrkSAAAAAOIwNj-IY-Q-p90hQrLinRIpZBPi'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    local SHORT=$(basename_file "$URL")

    # Should return {"success":1}
    JSON2=$(curl -b "$COOKIEFILE" --referer "$URL" --data \
        "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD&recaptcha_shortencode_field=$SHORT" \
        "http://www.fileserve.com/checkReCaptcha.php") || return

    local RET=$(echo "$JSON2" | parse_quiet 'success' 'success"\?[[:space:]]\?:[[:space:]]\?\([[:digit:]]*\)')
    if [ "$RET" != "1" ] ; then
        recaptcha_nack $ID
        log_error "wrong captcha"
        return $ERR_CAPTCHA
    fi

    recaptcha_ack $ID
    log_debug "correct captcha"
    MSG1=$(curl -b "$COOKIEFILE" --referer "$URL" --data "downloadLink=wait" "$URL") || return
    if match 'fail404' "$MSG1"; then
        log_error "unexpected result"
        return $ERR_FATAL
    fi

    WAIT_TIME=$(echo "$MSG1" | cut -b4-)
    wait $((WAIT_TIME + 1)) seconds || return
    MSG2=$(curl -b "$COOKIEFILE" --referer "$URL" --data "downloadLink=show" "$URL") || return

    MSG3=$(curl -i -b "$COOKIEFILE" --referer "$URL" --data "download=normal" "$URL") || return
    if match 'daily download limit has been reached' "$MSG3"; then
        log_error "Daily download limit reached, wait or use a premium account."
        return $ERR_FATAL
    fi

    FILE_URL=$(echo "$MSG3" | grep_http_header_location) || return

    echo "$FILE_URL"
}

# Upload a file to fileserve
# http://www.fileserve.com/script/upload-v3.js
# $1: cookie file (unused)
# $2: input file (with full path)
# $3: remote filename
# stdout: download + del link on fileserve
fileserve_upload() {
    eval "$(process_options fileserve "$MODULE_FILESERVE_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local FILE="$2"
    local DESTFILE="$3"
    local BASEURL='http://www.fileserve.com'

    local USERID SID TIMEOUT

    USERID='-1'
    TIMEOUT='5000'

    # Attempt to authenticate
    if test "$AUTH"; then
        fileserve_login "$AUTH" "$COOKIEFILE" "$BASEURL" >/dev/null || return
        PAGE=$(curl -b "$COOKIEFILE" "$BASEURL/upload-file.php") || return
        USERID=$(echo "$PAGE" | parse 'fileserve\.com\/upload\/'  'upload\/\([^\/]*\)') || return
        log_debug "userId: $USERID"
    fi

    # Get sessionId
    # Javascript: "now = new Date(); print(now.getTime());"
    T="$(date +%s)000"
    JSON=$(curl --referer "$BASEURL/" -H "Expect:" \
            "http://upload.fileserve.com/upload/$USERID/$TIMEOUT/?callback=jsonp$T&_=$$") || return

    if ! match 'waiting' "$JSON"; then
        log_debug "wrong sessionId state: $JSON"
        return $ERR_FATAL
    fi

    SID=$(echo "$JSON" | parse 'sessionId' "Id:'\([^']*\)") || return
    log_debug "sessionId: $SID"

    PAGE=$(curl_with_log --referer "$BASEURL/" -H "Expect:" \
            -F "file=@$FILE;filename=$DESTFILE" \
            "http://upload.fileserve.com/upload/$USERID/$TIMEOUT/$SID/" | break_html_lines) || return

    if match 'HTTP Status 400' "$PAGE"; then
        log_error "http error 400"
        return $ERR_FATAL
    fi

    # parse jsonp result
    ID=$(echo "$PAGE" | parse_quiet 'shortenCode' 'shortenCode":"\([^"]*\)') || return
    ID_DEL=$(echo "$PAGE" | parse_quiet 'deleteCode' 'deleteCode":"\([^"]*\)') || return
    FILENAME=$(echo "$PAGE" | parse_quiet 'fileName' 'fileName":"\([^"]*\)') || return

    echo "$BASEURL/file/$ID/$FILENAME ($BASEURL/file/$ID/delete/$ID_DEL)"
    return 0
}

# List a fileserve public folder URL
# $1: fileserve url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
fileserve_list() {
    local URL="$1"

    if ! match 'fileserve\.com/list/' "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    PAGE=$(curl "$URL" | grep '<a href="/file/')

    if test -z "$PAGE"; then
        log_error "Wrong directory list link"
        return $ERR_FATAL
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

# Delete a file from fileserve
# $1: delete link
fileserve_delete() {
    eval "$(process_options zshare "$MODULE_FILESERVE_DELETE_OPTIONS" "$@")"

    local URL="$1"
    local DELETE_PAGE NEED_CODE

    DELETE_PAGE=$(curl -L "$URL") || return
    NEED_CODE=$(parse 'confirm_delete_file' 'style="\([^"]*\)' <<<"$DELETE_PAGE")

    if [ "$NEED_CODE" = 'display:block' ]; then
        local BASEURL='http://www.fileserve.com'

        log_debug "Confirmation code required to confirm deletion"

        if [ -z "$CONFIRM_CODE" ]; then
            CONFIRM_CODE=$(prompt_for_password) || return
        fi

        local FORM_HTML FORM_ACTION FORM_URL FORM_DELETEURL
        FORM_HTML=$(grep_form_by_name "$DELETE_PAGE" 'confirmDeleteFolderForm')
        FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action)
        FORM_URL=$(echo "$FORM_HTML" | parse_form_input_by_name 'url')
        FORM_DELETEURL=$(echo "$FORM_HTML" | parse_form_input_by_name 'deleteUrl')

        DELETE_PAGE=$(curl -v --data \
                "confirmationCode=${CONFIRM_CODE}&url=${FORM_URL}&deleteUrl=$FORM_DELETEURL" \
                "$BASEURL$FORM_ACTION") || return

        # FIXME
        # <span id="confirm_delete_error" class="fail_info">Invalid cofirmation code. Please try again.</span>

    elif matchi 'File Delete Fail.' "$DELETE_PAGE"; then
        return $ERR_LINK_DEAD
    elif matchi 'File Deleted.' "$DELETE_PAGE"; then
        return 0
    fi

    return $ERR_FATAL
}
