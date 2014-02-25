#!/bin/bash
#
# 4shared.com module
# Copyright (c) 2010-2014 Plowshare team
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

MODULE_4SHARED_REGEXP_URL='https\?://\(www\.\)\?4shared\.com/'

MODULE_4SHARED_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files
TORRENT,,torrent,,Get torrent link (instead of direct download link)"
MODULE_4SHARED_DOWNLOAD_RESUME=yes
MODULE_4SHARED_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_4SHARED_DOWNLOAD_SUCCESSIVE_INTERVAL=5

MODULE_4SHARED_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account (mandatory)"
MODULE_4SHARED_UPLOAD_REMOTE_SUPPORT=no

MODULE_4SHARED_LIST_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
DIRECT_LINKS,,direct,,Show direct links (if available) instead of regular ones
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected folder"
MODULE_4SHARED_LIST_HAS_SUBFOLDERS=yes

MODULE_4SHARED_PROBE_OPTIONS=""

# Static function. Proceed with login (tested on free-membership)
4shared_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA NAME

    LOGIN_DATA='login=$USER&password=$PASSWORD&doNotRedirect=true'
    post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/web/login" -o /dev/null || return

    # On success, add cookie entries: Login & Password
    NAME=$(parse_cookie_quiet 'Login' < "$COOKIE_FILE")
    if [ -n "$NAME" ]; then
        return 0
    fi

    return $ERR_LOGIN_FAILED
}

# Output a 4shared file download URL
# $1: cookie file
# $2: 4shared url
# stdout: real file download link
4shared_download() {
    local -r COOKIEFILE=$1
    local URL=$2
    local -r BASE_URL='https://www.4shared.com'
    local REAL_URL URL PAGE WAIT_URL FILE_URL FILE_NAME

    if [ -z "$AUTH_FREE" ]; then
        log_error '4shared does not allow anonymous file download. Add --auth-free option.'
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    REAL_URL=$(curl -I "$URL" | grep_http_header_location_quiet) || return
    if test "$REAL_URL"; then
        URL=$REAL_URL
    fi

    if [ -n "$AUTH_FREE" ]; then
        4shared_login "$AUTH_FREE" "$COOKIEFILE" "$BASE_URL" || return
        # add new entries in $COOKIEFILE
        PAGE=$(curl -b "$COOKIEFILE" -c "$COOKIEFILE" -b '4langcookie=en' "$URL") || return
    else
        PAGE=$(curl -c "$COOKIEFILE" -b '4langcookie=en' "$URL") || return
    fi

    if match '4shared\.com/dir/' "$URL"; then
        log_error 'This is a directory list, use plowlist!'
        return $ERR_FATAL
    elif match 'The file link that you requested is not valid.' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # You must enter a password to access this file.
    if match 'enter a password to access' "$PAGE"; then
        log_debug 'File is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        local FORM_HTML FORM_ACTION FORM_DSID
        FORM_HTML=$(grep_form_by_name "$PAGE" 'theForm') || return
        FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
        FORM_DSID=$(echo "$FORM_HTML" | parse_form_input_by_name 'dsid')

        PAGE=$(curl -b "$COOKIEFILE" -c "$COOKIEFILE" -b '4langcookie=en' \
            -d "userPass2=$LINK_PASSWORD" \
            -d "dsid=$FORM_DSID" \
            "$FORM_ACTION") || return

        # The password you have entered is not valid
        if match 'enter a password to access' "$PAGE"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        fi
    fi

    # Try to figure real filename from HTML
    # - trinityConfig.globalFileName = '...'
    FILE_NAME=$(parse_all_quiet 'trinityConfig.globalFileName' '=[[:space:]]*["'\'']\([^/"'\'']*\)' <<< "$PAGE")

    # - <meta property="og:title" content="..."/>
    # Warning: filename without extension
    if [ -z "$FILE_NAME" ]; then
        FILE_NAME=$(echo "$PAGE" | parse_attr_quiet 'og:title' 'content')
    fi

    # - <h1 class="fileName light-blue lucida f24"> ... </h1>
    if [ -z "$FILE_NAME" ]; then
        FILE_NAME=$(echo "$PAGE" | parse_tag '=.fileName' 'h1')
    fi

    # Special case for /photo/ URLs
    FILE_URL=$(echo "$PAGE" | parse_attr_quiet '?forceAttachmentDownload=' href)
    if [ -n "$FILE_URL" ]; then
        echo "$FILE_URL"
        return 0
    fi

    WAIT_URL=$(parse_attr '4shared\.com/get/' href <<< "$PAGE") || return


    # Note: There is a strange entry required in cookie file: efdcyqLAT_3Q=1
    WAIT_HTML=$(curl -L -b "$COOKIEFILE" -b '4langcookie=en' --referer "$URL" "$WAIT_URL") || return

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

    if match 'Login</a> to download this file' "$WAIT_HTML"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    # <div class="sec" id='downloadDelayTimeSec'>20</div>
    WAIT_TIME=$(echo "$WAIT_HTML" | parse_tag_quiet 'downloadDelayTimeSec' 'div')
    test -z "$WAIT_TIME" && WAIT_TIME=20

    # Sanity check
    if match 'The file link that you requested is not valid\.' "$WAIT_HTML"; then
        return $ERR_LINK_DEAD
    fi

    if [ -z "$TORRENT" ]; then
        FILE_URL=$(echo "$WAIT_HTML" | parse_attr_quiet 'linkShow' href)
        if [ -z "$FILE_URL" ]; then
            FILE_URL=$(echo "$WAIT_HTML" | parse 'window\.location' '= "\([^"]*\)') || return
        fi
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
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local BASE_URL='http://www.4shared.com'
    local PAGE JSON DESTFILE_ENC UP_URL DL_URL FILE_ID DIR_ID LOGIN_ID PASS_HASH
    local SZ SIZE_LIMIT

    test "$AUTH_FREE" || return $ERR_LINK_NEED_PERMISSIONS

    4shared_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/account/home.jsp") || return

    DIR_ID=$(parse 'AjaxFacade\.rootDirId' \
            "=[[:space:]]*'\([^']\+\)" <<< "$PAGE") || return

    # Not required. Example: {"freeSpace":16102203291}
    JSON=$(curl -b "$COOKIE_FILE" "$BASE_URL/rest/account/freeSpace?dirId=$DIR_ID") || return
    SZ=$(get_filesize "$FILE")
    SIZE_LIMIT=$(echo "$JSON" | parse_json freeSpace) || return

    if [ "$SZ" -gt "$SIZE_LIMIT" ]; then
        log_debug "file is bigger than $SIZE_LIMIT"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    DESTFILE_ENC=$(echo "$DESTFILE" | uri_encode_strict)
    LOGIN_ID=$(parse_cookie 'Login' < "$COOKIE_FILE") || return
    PASS_HASH=$(parse_cookie 'Password' < "$COOKIE_FILE") || return

    JSON=$(curl -b "$COOKIE_FILE" -X POST \
        -H "x-security: $LOGIN_ID" \
        "$BASE_URL/rest/sharedFileUpload/create?dirId=$DIR_ID&name=$DESTFILE_ENC&size=$SZ") || return

    # {"status":true,"url":"","http://...
    if ! match_json_true 'status' "$JSON"; then
        return $ERR_FATAL
    fi

    UP_URL=$(echo "$JSON" | parse_json url) || return
    DL_URL=$(echo "$JSON" | parse_json d1link) || return
    FILE_ID=$(echo "$JSON" | parse_json fileId) || return
    DIR_ID=$(echo "$JSON" | parse_json uploadDir)

    JSON=$(curl_with_log -X POST --data-binary "@$FILE" \
        -H "x-root-dir: $DIR_ID" \
        -H "x-upload-dir: $DIR_ID" \
        -H "x-file-name: $DESTFILE_ENC" \
        -H "Content-Type: application/octet-stream" \
        "$UP_URL&resumableFileId=$FILE_ID&resumableFirstByte=0&sectionSize=$SZ&cuid=$LOGIN_ID&cupa=$PASS_HASH") || return

    # I should get { "status": "OK", "uploadedFileId": -1, "fileUploadUrl": "" }
    local STATUS ERR
    STATUS=$(echo "$JSON" | parse_json_quiet status)
    if [ "$STATUS" != 'OK' ]; then
        ERR=$(echo "$JSON" | parse_json Message)
        log_debug "Bad status: $STATUS"
        test "$ERR" && log_error "Remote error: $ERR"
        return $ERR_FATAL
    fi

    BASE_URL=$(basename_url "$UP_URL")
    JSON=$(curl -X POST -H 'Content-Type: ' \
        -H "x-root-dir: $DIR_ID" \
        -H "x-cookie: Login=$LOGIN_ID; Password=$PASS_HASH;" \
        "$BASE_URL/rest/sharedFileUpload/finish?fileId=$FILE_ID") || return

    log_debug "JSON: '$JSON'"
    # {"status":true}
    #if ! match_json_true 'status' "$JSON"; then
    #    log_error 'bad answer, file moved to Incompleted folder'
    #    return $ERR_FATAL
    #fi

    echo "$DL_URL"
}

# List a 4shared folder URL
# $1: 4shared.com link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
4shared_list() {
    local URL=$(echo "$1" | replace '/folder/' '/dir/')
    local BASE_URL='https://www.4shared.com'
    local COOKIE_FILE RET=0

    # There are two views:
    # - Simple view link (URL with /folder/)
    # - Advanced view link (URL with /dir/)
    if ! match '4shared\.com/dir/' "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    COOKIE_FILE=$(create_tempfile) || return
    4shared_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || RET=$?

    if [ $RET -eq 0 ]; then
        4shared_list_rec "$2" "$URL" "$COOKIE_FILE" || RET=$?
    fi

    rm -f "$COOKIE_FILE"
    return $RET
}

# static recursive function
# $1: recursive flag
# $2: web folder URL
# $3: cookie file
4shared_list_rec() {
    local REC=$1
    local URL=$2
    local -r COOKIE_FILE=$3
    local -r BASE_URL='http://www.4shared.com'

    local PAGE LINKS NAMES RET LINE SID DIR_ID JSON

    RET=$ERR_LINK_DEAD
    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b '4langcookie=en' \
        "$URL") || return

    # Please enter a password to access this folder
    if match 'enter a password to access' "$PAGE"; then
        log_debug 'Folder is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        local FORM_HTML FORM_ACTION FORM_DSID
        FORM_HTML=$(grep_form_by_name "$PAGE" 'theForm') || return
        FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
        FORM_DSID=$(echo "$FORM_HTML" | parse_form_input_by_name 'dsid')

        PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b '4langcookie=en' \
            -d "userPass2=$LINK_PASSWORD" \
            -d "dsid=$FORM_DSID" \
            "$FORM_ACTION") || return

        # The password you have entered is not valid
        if match 'enter a password to access' "$PAGE"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        fi
    fi

    # Sanity chech
    if match 'src="/images/spacer.gif" class="warn"' "$PAGE"; then
        log_error 'Site updated ?'
        return $ERR_FATAL
    fi

    if test "$DIRECT_LINKS"; then
        log_debug 'Note: provided links are temporary! Use "curl -J -O" on it.'
        LINKS=$(echo "$PAGE" | \
            parse_all_attr_quiet 'class="icon16 download"' href)
        list_submit "$LINKS" && RET=0
    else
        DIR_ID=$(echo "$PAGE" | parse 'AjaxFacade\.rootDirId' \
            "=[[:space:]]*'\([^']\+\)") || return
        JSON=$(curl -b "$COOKIE_FILE" -b '4langcookie=en' -d "dirId=$DIR_ID" \
            "$BASE_URL/web/accountActions/changeDir") || return

        LINKS=$(parse_json 'id' split <<<"$JSON")
        NAMES=$(parse_json 'name' split <<<"$JSON")
        list_submit "$LINKS" "$NAMES" "$BASE_URL/file/" '/' && RET=0
    fi

    # Are there any subfolders?
    if test "$REC"; then
        LINKS=$(parse_all_quiet ':changeDir(' '(\([[:digit:]]\+\)' <<< "$PAGE")
        SID=$(parse_form_input_by_name 'sId' <<< "$PAGE") || return
        while read LINE; do
            test "$LINE" || continue
            URL="http://www.4shared.com/account/changedir.jsp?sId=$SID&ajax=false&changedir=$LINE&random=0"
            log_debug "entering sub folder: $URL"
            4shared_list_rec "$REC" "$URL" "$COOKIE_FILE" && RET=0
        done <<< "$LINKS"
    fi

    return $RET
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: 4shared.com url
# $3: requested capability list
# stdout: 1 capability per line
4shared_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT

    PAGE=$(curl --location -b '4langcookie=en' "$URL") || return

    if ! match '<meta[[:space:]]*property=.og:url' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_attr_quiet 'og:title' 'content' <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    echo $REQ_OUT
}
