#!/bin/bash
#
# 4shared.com module
# Copyright (c) 2010-2012 Plowshare team
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

MODULE_4SHARED_REGEXP_URL="https\?://\(www\.\)\?4shared\.com/"

MODULE_4SHARED_DOWNLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free account
TORRENT,,torrent,,Get torrent link (instead of direct download link)"
MODULE_4SHARED_DOWNLOAD_RESUME=yes
MODULE_4SHARED_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_4SHARED_UPLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free account"
MODULE_4SHARED_UPLOAD_REMOTE_SUPPORT=no

MODULE_4SHARED_LIST_OPTIONS="
DIRECT_LINKS,,direct,,Show direct links (if available) instead of regular ones"

# Static function. Proceed with login (tested on free-membership)
4shared_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASEURL=$3
    local LOGIN_DATA JSON_RESULT ERR

    LOGIN_DATA='login=$USER&password=$PASSWORD&doNotRedirect=true'
    JSON_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASEURL/login") || return

    # {"ok":true,"rejectReason":"","loginRedirect":"http://...
    if match '"ok"[[:space:]]\?:[[:space:]]\?true' "$JSON_RESULT"; then
        echo "$JSON_RESULT"
        return 0
    fi

    ERR=$(echo "$JSON_RESULT" | parse 'rejectReason' \
        'rejectReason"[[:space:]]\?:[[:space:]]\?"\([^"]*\)')
    log_debug "remote says: $ERR"
    return $ERR_LOGIN_FAILED
}

# Output a 4shared file download URL
# $1: cookie file
# $2: 4shared url
# stdout: real file download link
4shared_download() {
    eval "$(process_options 4shared "$MODULE_4SHARED_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$2
    local BASE_URL='https://www.4shared.com'
    local REAL_URL URL PAGE WAIT_URL FILE_URL FILE_NAME

    REAL_URL=$(curl -I "$URL" | grep_http_header_location_quiet) || return
    if test "$REAL_URL"; then
        URL=$REAL_URL
    fi

    if [ -n "$AUTH_FREE" ]; then
        4shared_login "$AUTH_FREE" "$COOKIEFILE" "$BASE_URL" >/dev/null || return
        # add new entries in $COOKIEFILE
        PAGE=$(curl -b "$COOKIEFILE" -c "$COOKIEFILE" -b '4langcookie=en' "$URL") || return
    else
        PAGE=$(curl -c "$COOKIEFILE" -b '4langcookie=en' "$URL") || return
    fi

    if match '4shared\.com/dir/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return $ERR_FATAL
    elif match 'The file link that you requested is not valid.' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    WAIT_URL=$(echo "$PAGE" | parse_attr '4shared\.com\/get\/' 'href') || return

    test "$CHECK_LINK" && return 0

    # Note: There is a strange entry required in cookie file: efdcyqLAT_3Q=1
    WAIT_HTML=$(curl -L -b "$COOKIEFILE" --referer "$URL" "$WAIT_URL") || return

    # Redirected in case of error
    if [ -z "$WAIT_HTML" ]; then
        URL=$(curl -I -b "$COOKIEFILE" "$WAIT_URL" | grep_http_header_location)
        if match 'err=not-logged$' "$URL"; then
            return $ERR_LINK_NEED_PERMISSIONS
        else
           log_error "Unexpected redirection: $URL"
           return $ERR_FATAL
        fi
    fi

    WAIT_TIME=$(echo "$WAIT_HTML" | parse 'var c =' \
            '[[:space:]]\([[:digit:]]\+\);')

    # Try to figure the real filename from HTML
    FILE_NAME=$(echo "$WAIT_HTML" | parse_quiet '<b class="blue xlargen">' \
            'n">\([^<]\+\)' | html_to_utf8 | uri_decode)

    if [ -z "$TORRENT" ]; then
        FILE_URL=$(echo "$WAIT_HTML" | parse_attr '4shared\.com\/download\/' href) || return
    else
        MODULE_4SHARED_DOWNLOAD_RESUME=no
        FILE_URL=$(echo "$WAIT_HTML" | parse_attr 'download-torrent' href) || return
        FILE_NAME="${FILE_NAME}.torrent"
    fi

    wait $((WAIT_TIME)) seconds || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to 4shared
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download + del link
4shared_upload() {
    eval "$(process_options 4shared "$MODULE_4SHARED_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://www.4shared.com'
    local PAGE JSON DESTFILE_ENC SZ UP_URL DL_URL FILE_ID DIR_ID LOGIN_ID PASS_HASH

    if [ -z "$AUTH_FREE" ]; then
        log_error "Anonymous users cannot upload files"
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    4shared_login "$AUTH_FREE" "$COOKIEFILE" "$BASE_URL" >/dev/null || return

    PAGE=$(curl -b "$COOKIEFILE" "$BASE_URL/account/home.jsp") || return
    DIR_ID=$(echo "$PAGE" | parse 'AjaxFacade\.rootDirId' '=[[:space:]]*\([[:digit:]]\+\)')

    # Not required. Example: {"freeSpace":16102203291}
    #JSON=$(curl -b "$COOKIEFILE" "$BASE_URL/rest/account/freeSpace?dirId=$DIR_ID") || return

    SZ=$(get_filesize "$FILE")
    DESTFILE_ENC=$(echo "$DESTFILE" | uri_encode_strict)

    # Note: x-cookie missing
    JSON=$(curl -b "$COOKIEFILE" -X POST \
        "$BASE_URL/rest/sharedFileUpload/create?dirId=$DIR_ID&name=$DESTFILE_ENC&size=$SZ") || return

    # {"status":true,"url":"","http://...
    if ! match '"status"[[:space:]]\?:[[:space:]]\?true' "$JSON"; then
        return $ERR_FATAL
    fi

    UP_URL=$(echo "$JSON" | parse 'url' 'url"[[:space:]]\?:[[:space:]]\?"\([^"]*\)') || return
    DL_URL=$(echo "$JSON" | parse 'd1link' 'd1link"[[:space:]]\?:[[:space:]]\?"\([^"]*\)') || return
    FILE_ID=$(echo "$JSON" | parse 'fileId' 'fileId"[[:space:]]\?:[[:space:]]\?\([^,]*\)')
    DIR_ID=$(echo "$JSON" | parse 'uploadDir' 'uploadDir"[[:space:]]\?:[[:space:]]\?\([^,]*\)')

    # Note: x-cookie missing
    JSON=$(curl_with_log -X POST --data-binary "@$FILE" \
        -H "x-root-dir: $DIR_ID" \
        -H "x-upload-dir: $DIR_ID" \
        -H "x-file-name: $DESTFILE_ENC" \
        -H "Content-Type: application/octet-stream" \
        "$UP_URL&resumableFileId=$FILE_ID&resumableFirstByte=0") || return

    # I should get { "status": "OK", "uploadedFileId": -1 }
    if match '"status"[[:space:]]\?:[[:space:]]\?"error"' "$JSON"; then
        local ERR=$(echo "$JSON" | parse 'Message"' "Message\"[[:space:]]\?:[[:space:]]\?'\([^']*\)") || return
        log_error "site: $ERR"
        return $ERR_FATAL
    fi

    BASE_URL=$(basename_url "$UP_URL")
    LOGIN_ID=$(parse_cookie 'Login' < "$COOKIEFILE")
    PASS_HASH=$(parse_cookie 'Password' < "$COOKIEFILE")

    # Note: x-cookie required here
    JSON=$(curl -X POST -H 'Content-Type: ' \
        -H "x-root-dir: $DIR_ID" \
        -H "x-cookie: Login=$LOGIN_ID; Password=$PASS_HASH;" \
        "$BASE_URL/rest/sharedFileUpload/finish?fileId=$FILE_ID") || return

    echo "$DL_URL"

    # {"status":true}
    if ! match '"status"[[:space:]]\?:[[:space:]]\?true' "$JSON"; then
        log_error "bad answer, file moved to Incompleted folder"
        return $ERR_FATAL
    fi
}

# List a 4shared folder URL
# $1: 4shared.com link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
4shared_list() {
    eval "$(process_options 4shared "$MODULE_4SHARED_LIST_OPTIONS" "$@")"

    local URL=$(echo "$1" | replace '/folder/' '/dir/')
    local PAGE

    # There are two views:
    # - Simple view link (URL with /folder/)
    # - Advanced view link (URL with /dir/)
    if ! match '4shared\.com/dir/' "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    test "$2" && log_debug "recursive flag is not supported"

    PAGE=$(curl "$URL") || return

    match 'src="/images/spacer.gif" class="warn"' "$PAGE" &&
        { log_error "Site updated?"; return $ERR_FATAL; }

    if test "$DIRECT_LINKS"; then
        log_debug "Note: provided links are temporary! Use 'curl -J -O' on it."
        echo "$PAGE" | parse_all_attr_quiet \
            'class="icon16 download"' href || return $ERR_LINK_DEAD
    else
        echo "$PAGE" | parse_all "openNewWindow('" \
            "('\([^']*\)" || return $ERR_LINK_DEAD
    fi
}
