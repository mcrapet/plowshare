#!/bin/bash
#
# extabit.com module
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

MODULE_EXTABIT_REGEXP_URL="http://\(www\.\)\?extabit\.com/file/"

MODULE_EXTABIT_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account"
MODULE_EXTABIT_DOWNLOAD_RESUME=no
MODULE_EXTABIT_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_EXTABIT_UPLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account (mandatory)"
MODULE_EXTABIT_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login (free or premium)
extabit_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT STATUS

    LOGIN_DATA='email=$USER&pass=$PASSWORD&remember=1&auth_submit_login.x=33&auth_submit_login.y=5'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.jsp" -b 'language=en' -L) || return

    # If successful, two entries are added into cookie file: auth_uid and auth_hash
    STATUS=$(parse_cookie_quiet 'auth_hash' < "$COOKIE_FILE")
    if [ -z "$STATUS" ]; then
        return $ERR_LOGIN_FAILED
    fi

    match 'Premium is active' "$LOGIN_RESULT" && \
        echo 'premium' || echo 'free'
}

# Output an extabit.com file download URL
# $1: cookie file
# $2: extabit url
# stdout: real file download link
extabit_download() {
    local COOKIE_FILE=$1
    local URL=$2
    local BASE_URL='http://extabit.com'
    local REDIR PAGE DIV_ID WAIT_TIME JSON ERR QUERY FILE_NAME FILE_URL TYPE

    REDIR=$(curl -i "$URL" | grep_http_header_location_quiet)
    [ -n "$REDIR" ] && URL=$REDIR

    if [ -n "$AUTH" ]; then
        TYPE=$(extabit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
        log_debug "Account type: $TYPE"

        if [ "$TYPE" != 'free' ]; then
            MODULE_EXTABIT_DOWNLOAD_RESUME=yes

            # Detect "Direct links" option
            PAGE=$(curl -I -b "$COOKIE_FILE" "$URL") || return

            FILE_URL=$(echo "$PAGE" | grep_http_header_location_quiet)
            if [ -z "$FILE_URL" ]; then
                PAGE=$(curl -b "$COOKIE_FILE" -b 'language=en' "$URL") || return

                # Duplicated from below
                match 'page_404_header' "$PAGE" && return $ERR_LINK_DEAD

                FILE_URL=$(echo "$PAGE" | parse_attr 'download-file-btn' href) || return
                FILE_NAME=$(echo "$PAGE" | parse_attr 'div title' title)
            else
                FILE_NAME=$(curl -I "$FILE_URL" | \
                    grep_http_header_content_disposition) || return
            fi

            echo "$FILE_URL"
            echo "$FILE_NAME"
            return 0
        fi

        PAGE=$(curl -b "$COOKIE_FILE" -b 'language=en' "$URL") || return
    else
        PAGE=$(curl -c "$COOKIE_FILE" -b 'language=en' "$URL") || return
    fi

    # <h1>File not found</h1>
    if match 'page_404_header' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Next free download from your ip will be available in
    if match 'free download from your ip' "$PAGE"; then
        WAIT_TIME=$(echo "$PAGE" | parse 'download-link' \
            '<b>\([[:digit:]]\+\) minute' 1)
        echo $((WAIT_TIME * 60))
        return $ERR_LINK_TEMP_UNAVAILABLE

    # Only premium users can download this file.
    elif match 'premium users can download' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FILE_NAME=$(echo "$PAGE" | parse_attr 'div title' title)
    DIV_ID=$(echo "$PAGE" | parse '\.captchatimer' "#\([^']\+\)") || return
    WAIT_TIME=$(echo "$PAGE" | parse_tag "=\"$DIV_ID\"" div) || return

    wait $((WAIT_TIME)) || return

    # reCaptcha part
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6LcEvs0SAAAAAAykpzcaaxpegnSndWcEWYsSMs0M'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    JSON=$(curl --get -b "$COOKIE_FILE" -b 'language=en' \
        -d 'type=recaptcha' \
        -d "challenge=$CHALLENGE" \
        -d "capture=$WORD" \
        "$URL") || return

    # Sanity check
    [ -z "$JSON" ] && \
        log_error "Bad state. Empty answer"

    #{"err":"Entered digits are incorrect."}
    #{"ok":true,"href":"?af"}
    if ! match_json_true 'ok' "$JSON"; then
        ERR=$(echo "$JSON" | parse_json_quiet err)
        test "$ERR" && log_error "Remote error: $ERR"

        captcha_nack $ID
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug "correct captcha"

    QUERY=$(echo "$JSON" | parse_json href) || return
    PAGE=$(curl --get -b "$COOKIE_FILE" -b 'language=en' \
        "$URL$QUERY") || return

    FILE_URL=$(echo "$PAGE" | parse_attr 'Download file' href) || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to extabit.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: extabit.com download link
extabit_upload() {
    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://extabit.com'
    local PAGE

    test "$AUTH" || return $ERR_LINK_NEED_PERMISSIONS

    # Official API is quite incomplete.
    # http://code.google.com/p/extabit-api/wiki/APIDocumentation

    extabit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" > /dev/null || return
    PAGE=$(curl -L -b "$COOKIE_FILE" -b 'language=en' "$BASE_URL") || return

    local FORM_HTML FORM_ACTION FORM_MAXFSIZE
    FORM_HTML=$(grep_form_by_id "$PAGE" 'upload_files_form') || return

    # onclick="alert('Sorry, temporary disabled');
    if match 'temporary disabled' "$FORM_HTML"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_MAXFSIZE=$(echo "$FORM_HTML" | parse_form_input_by_name 'MAX_FILE_SIZE')

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$FORM_MAXFSIZE" ]; then
        log_debug "file is bigger than $FORM_MAXFSIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    PAGE=$(curl_with_log -L -b "$COOKIE_FILE" \
        -F "MAX_FILE_SIZE=$FORM_MAXFSIZE"    \
        -F "my_file=@$FILE;filename=$DESTFILE" \
        -F 'checkbox_terms=on' \
        "$FORM_ACTION") || return

    echo "$PAGE" | parse_attr 'df_html_link' 'href' || return
}
