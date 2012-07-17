#!/bin/bash
#
# filemates.com module
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
#
# Note: This module is a clone of ryushare.

MODULE_FILEMATES_REGEXP_URL="http://\(www\.\)\?filemates\.com/"

MODULE_FILEMATES_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_FILEMATES_DOWNLOAD_RESUME=no
MODULE_FILEMATES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

# Static function. Proceed with login (free or premium)
# $1: authentication
# $2: cookie file
filemates_login() {
    local COOKIE_FILE=$2
    local BASE_URL='http://filemates.com'

    local LOGIN_DATA LOGIN_RESULT NAME

    LOGIN_DATA='op=login&login=$USER&password=$PASSWORD&redirect='
    LOGIN_RESULT=$(post_login "$1" "$COOKIE_FILE" "$LOGIN_DATA$BASE_URL" "$BASE_URL") || return

    # Set-Cookie: login xfss
    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -n "$NAME" ]; then
        log_debug "Successfully logged in as $NAME member"
        return 0
    fi

    return $ERR_LOGIN_FAILED
}

# Output a filemates file download URL
# $1: cookie file
# $2: filemates url
# stdout: real file download link
filemates_download() {
    local COOKIE_FILE=$1
    local URL=$2
    local PAGE FILE_URL ACCOUNT
    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_RAND FORM_METHOD

    if [ -n "$AUTH_FREE" ]; then
        filemates_login "$AUTH_FREE" "$COOKIE_FILE" || return

        # Distinguish acount type (free or premium)
        PAGE=$(curl -b "$COOKIE_FILE" 'http://www.filemates.com/?op=my_account') || return
        ACCOUNT=$(echo "$PAGE" | parse 'User level' '^[[:space:]]*\([^<]*\)' 3)
        if [ "$ACCOUNT" != 'Free' ]; then
            log_error "Premium users not handled. Sorry"
        fi
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

    # The file was removed by administrator
    # The file was deleted by ...
    if matchi 'file was \(removed\|deleted\)' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Send (post) form
    # Note: usr_login is empty even if logged in
    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op')
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
    FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname')
    FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')

    PAGE=$(curl -b "$COOKIE_FILE" -F 'referer=' \
        -F "op=$FORM_OP" \
        -F "usr_login=$FORM_USR" \
        -F "id=$FORM_ID" \
        -F "fname=$FORM_FNAME" \
        -F "method_free=$FORM_METHOD" "$URL") || return

    if match '<div class="err"' "$PAGE"; then
        # You can download files up to 400 Mb only.
        # Upgrade your account to download bigger files.
        if matchi 'upgrade your account to download' "$PAGE"; then
            return $ERR_LINK_NEED_PERMISSIONS

        # You have to wait X minutes, Y seconds till next download
        elif matchi 'You have to wait' "$PAGE"; then
            local MINS SECS
            MINS=$(echo "$PAGE" | \
                parse_quiet 'class="err"' 'wait \([[:digit:]]\+\) minute')
            SECS=$(echo "$PAGE" | \
                parse_quiet 'class="err"' ', \([[:digit:]]\+\) second')

            echo $(( MINS * 60 + SECS ))
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi
    fi

    # File Password (ask the uploader to give you this key)
    if match '"password"' "$PAGE"; then
        log_debug "File is password protected"
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD="$(prompt_for_password)" || return
        fi
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
    FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand')
    FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name 'method_free')

    # <span id="countdown_str">Wait <span id="phmz1e">60</span> seconds</span>
    WAIT_TIME=$(echo "$PAGE" | parse_tag countdown_str span)
    wait $((WAIT_TIME + 1)) || return

    # Didn't included -d 'method_premium='
    PAGE=$(curl -i -b "$COOKIE_FILE" -d "referer=$URL" \
        -d "op=$FORM_OP" \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d "method_free=$FORM_METHOD" \
        -d "password=$LINK_PASSWORD" \
        "$URL") || return

    FILE_URL=$(echo "$PAGE" | grep_http_header_location_quiet)
    if match_remote_url "$FILE_URL"; then
        echo "$FILE_URL"
        echo "$FORM_FNAME"
        return 0
    fi

    if match '<div class="err"' "$PAGE"; then
        ERR=$(echo "$PAGE" | parse_tag  'class="err"' div)
        if match 'Wrong password' "$ERR"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        fi
        log_error "Remote error: $ERR"
    else
        log_error "Unexpected content, site updated?"
    fi

    return $ERR_FATAL
}
