#!/bin/bash
#
# filebox.com module
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

MODULE_FILEBOX_REGEXP_URL="https\?://\(www\.\)\?filebox\.com"

MODULE_FILEBOX_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_FILEBOX_DOWNLOAD_RESUME=yes
MODULE_FILEBOX_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

MODULE_FILEBOX_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_FILEBOX_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login
# $1: $AUTH argument string
# $2: cookie file
filebox_login() {
    local COOKIE_FILE=$2
    local BASE_URL='http://filebox.com'

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

# Output a filebox file download URL
# $1: cookie file
# $2: filebox url
# stdout: real file download link
filebox_download() {
    eval "$(process_options filebox "$MODULE_FILEBOX_DOWNLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local URL=$2

    local PAGE WAIT_TIME FILE_URL WAIT_NEEDED=1
    local FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_DD FORM_METHOD_F FORM_METHOD_P

    if [ -n "$AUTH" ]; then
        filebox_login "$AUTH" "$COOKIE_FILE" || return

        # Distinguish acount type (free or premium)
        PAGE=$(curl -b "$COOKIE_FILE" 'http://www.filebox.com/?op=my_account') || return

        # Opposite is: 'Upgrade to premium';
        match 'Renew premium' "$PAGE" && WAIT_NEEDED=0

        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return

        # Check for direct download account setting
        # (in fact it just sends the POST request for you)
        FILE_URL=$(echo "$PAGE" | \
            parse_all_attr_quiet ' Download File ' href | last_line)
        if [ -n "$FILE_URL" ]; then
            echo "$FILE_URL"
            return 0
        fi
    else
        PAGE=$(curl -b 'lang=english' "$URL") || return
    fi

    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    if [ $WAIT_NEEDED -ne 0 ]; then
        WAIT_TIME=$(echo "$PAGE" | parse_tag 'countdown_str">' span) || return
        wait $((WAIT_TIME)) || return
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand') || return
    FORM_DD=$(echo "$FORM_HTML" | parse_form_input_by_name 'down_direct') || return

    # Note: this is quiet parsing
    FORM_METHOD_F=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')
    FORM_METHOD_P=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_premium')

    if [ "$FORM_DD" = 0 ]; then
        log_error "$FUNCNAME: indirect download is not expected"
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -F 'referer=' \
        -F "op=$FORM_OP" \
        -F "id=$FORM_ID" \
        -F "rand=$FORM_RAND" \
        -F "down_direct=$FORM_DD" \
        -F "method_free=$FORM_METHOD_F" \
        -F "method_premium=$FORM_METHOD_P" \
        "$URL") || return

    # Page layout is different for videos
    if match 'embed' "$PAGE"; then
        FILE_URL=$(echo "$PAGE" | parse_all_attr '>Download ' href | last_line) || return
    else
        # >>> Download File <<<<
        # Note: less than and greater than should be entities (&lt; &gt;)
        FILE_URL=$(echo "$PAGE" | parse_all_attr ' Download File ' href | last_line) || return
    fi

    echo "$FILE_URL"
}

# Upload a file to filebox
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download_url
filebox_upload() {
    eval "$(process_options filebox "$MODULE_FILEBOX_UPLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://www.filebox.com'
    local PAGE SRV_CGI SIZE_LIMIT SESSID RESPONSE FILE_ID FILE_ORIG_ID DEL_LINK

    if [ -n "$AUTH" ]; then
        filebox_login "$AUTH" "$COOKIE_FILE" || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return
    SRV_CGI=$(echo "$PAGE" | parse "'script'" ":[[:space:]]*'\([^']\+\)") || return
    SIZE_LIMIT=$(echo "$PAGE" | parse "'sizeLimit'" ":[[:space:]]*\([^,]\+\)") || return

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$SIZE_LIMIT" ]; then
        log_debug "file is bigger than $SIZE_LIMIT"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Anonymous upload don't have SESSID
    SESSID=$(echo "$PAGE" | parse_quiet 'scriptData' ':[[:space:]]*"\([^"]*\)')
    [ -z "$SESSID" ] && SESSID=$(random d 16)

    # Uses Uploadify (jQuery plugin) v2.1.4 for files upload
    # But we don't care, we just call directly server side upload script (cgi)!
    RESPONSE=$(curl_with_log \
        -F "Filename=$DESTFILE" \
        -F "sess_id=$SESSID" \
        -F 'folder=/' \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        -F 'Upload=Submit Query' \
        "$SRV_CGI") || return

    # code : real : dx : fname : ftype
    # rvxv24pogkgl:rvxv24pogkgl:00068:foobar.zip:
    IFS=":" read FILE_ID FILE_ORIG_ID PAGE <<< "$RESPONSE"
    if [ "$FILE_ID" != "$FILE_ORIG_ID" ]; then
        log_debug "Upstream found similar upload: $BASE_URL/$FILE_ORIG_ID"
    fi

    PAGE=$(curl --get --referer "$BASE_URL" \
        -d 'op=upload_result' -d 'st=OK' \
        -d "fn=$FILE_ID" "$BASE_URL") || return

    DEL_LINK=$(echo "$PAGE" | parse_tag 'killcode' textarea)

    echo "$BASE_URL/$FILE_ID"
    echo "$DEL_LINK"
}
