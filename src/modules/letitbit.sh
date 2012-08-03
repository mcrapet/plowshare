#!/bin/bash
#
# letitbit module
# Copyright (c) 2011-2012 Plowshare team
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

MODULE_LETITBIT_REGEXP_URL="http://\(www\.\)\?letitbit\.net/"

MODULE_LETITBIT_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"
MODULE_LETITBIT_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base url
letitbit_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE ERR EMAIL

    LOGIN_DATA='act=login&login=$USER&password=$PASSWORD'
    PAGE=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/index.php" -b 'lang=en') || return

    # Note: Cookies "pas" + "log" (=login name) get set on successful login
    ERR=$(echo "$PAGE" | parse_tag_quiet 'error-text' 'span')

    if [ -n "$ERR" ]; then
        log_error "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    EMAIL=$(parse_cookie 'log' < "$COOKIE_FILE" | uri_decode) || return
    log_debug "Successfully logged in as member '$EMAIL'"
}

# Upload a file to Letitbit.net
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: letitbit download link
#         letitbit delete link
letitbit_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://letitbit.net'
    local PAGE SIZE MAX_SIZE UPLOAD_SERVER MARKER STATUS_URL
    local FORM_HTML FORM_OWNER FORM_PIN FORM_BASE FORM_HOST

    if [ -n "$AUTH_FREE" ]; then
        letitbit_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    else
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' "$BASE_URL") || return
    FORM_HTML=$(grep_form_by_id "$PAGE" 'upload_form') || return

    MAX_SIZE=$(echo "$FORM_HTML" | parse_form_input_by_name 'MAX_FILE_SIZE') || return
    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt "$MAX_SIZE" ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    FORM_OWNER=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'owner')
    FORM_PIN=$(echo "$FORM_HTML" | parse_form_input_by_name 'pin') || return
    FORM_BASE=$(echo "$FORM_HTML" | parse_form_input_by_name 'base') || return
    FORM_HOST=$(echo "$FORM_HTML" | parse_form_input_by_name 'host') || return

    UPLOAD_SERVER=$(echo "$PAGE" | parse 'var[[:space:]]\+ACUPL_UPLOAD_SERVER' \
        "=[[:space:]]\+'\([^']\+\)';") || return

    # marker/nonce is generated like this (from http://letitbit.net/acuploader/acuploader2.js)
    #
    # function randomString( _length ) {
    #   var chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXTZabcdefghiklmnopqrstuvwxyz';
    #   ... choose <_length_> random elements from array above ...
    # }
    # ...
    # <marker> = (new Date()).getTime().toString(16).toUpperCase() + '_' + randomString( 40 );
    #
    # example: 13B18CC2A5D_cwhOyTuzkz7GOsdU9UzCwtB0J9GSGXJCsInpctVV
    MARKER=$(printf "%X_%s" "$(date +%s000)" "$(random Ll 40)") || return

    # Upload local file
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' \
        -F "MAX_FILE_SIZE=$MAX_SIZE"           \
        -F "owner=$FORM_OWNER"                 \
        -F "pin=$FORM_PIN"                     \
        -F "base=$FORM_BASE"                   \
        -F "host=$FORM_HOST"                   \
        -F "file0=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        "http://$UPLOAD_SERVER/marker=$MARKER") || return

    if [ "$PAGE" != 'POST - OK' ]; then
        log_error "Unexpected response: $PAGE"
        return $ERR_FATAL
    fi

    # Get upload stats/result URL
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' --get \
        -d "srv=$UPLOAD_SERVER" -d "uid=$MARKER"     \
        "$BASE_URL/acupl_proxy.php") || return

    STATUS_URL=$(echo "$PAGE" | parse_json_quiet 'post_result')

    if [ -z "STATUS_URL" ]; then
        log_error "Unexpected response: $PAGE"
        return $ERR_FATAL
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' "$STATUS_URL") || return

    # extract + output download link + delete link
    echo "$PAGE" | parse "$BASE_URL/download/" \
        '<textarea[^>]*>\(http.\+html\)$' || return
    echo "$PAGE" | parse "$BASE_URL/download/delete" \
        '<div[^>]*>\(http.\+html\)<br/>' || return
}
