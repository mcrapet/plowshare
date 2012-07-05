#!/bin/bash
#
# netload.in module
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

MODULE_NETLOAD_IN_REGEXP_URL="http://\(www\.\)\?net\(load\|folder\)\.in/"

MODULE_NETLOAD_IN_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Premium account"
MODULE_NETLOAD_IN_DOWNLOAD_RESUME=no
MODULE_NETLOAD_IN_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_NETLOAD_IN_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Premium account"
MODULE_NETLOAD_IN_UPLOAD_REMOTE_SUPPORT=no

MODULE_NETLOAD_IN_LIST_OPTIONS="
LINK_PASSWORD,p:,link-password:,PASSWORD,Used for password-protected folder"

# Static function. Proceed with login
# $1: $AUTH argument string
# $2: cookie file
# $3: netload.in baseurl
netload_in_premium_login() {
    # Even if login/passwd are wrong cookie content is returned
    local LOGIN_DATA LOGIN_RESULT
    LOGIN_DATA='txtuser=$USER&txtpass=$PASSWORD&txtcheck=login&txtlogin='
    LOGIN_RESULT=$(post_login "$1" "$2" "$LOGIN_DATA" "$3/index.php" -L) || return

    if match 'InPage_Error\|lostpassword\.tpl' "$LOGIN_RESULT"; then
        log_debug "bad login and/or password"
        return $ERR_LOGIN_FAILED
    fi
}

# Output a netload.in file download URL
# $1: cookie file
# $2: netload.in url
# stdout: real file download link
netload_in_download() {
    eval "$(process_options netload_in "$MODULE_NETLOAD_IN_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$(echo "$2" | replace 'www.' '')
    local BASE_URL='http://netload.in'
    local PAGE WAIT_URL WAIT_HTML WAIT_TIME CAPTCHA_URL CAPTCHA_IMG FILENAME FILE_URL

    if [ -n "$AUTH" ]; then
        netload_in_premium_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return
        MODULE_NETLOAD_IN_DOWNLOAD_RESUME=yes

        PAGE=$(curl -i -b "$COOKIEFILE" "$URL") || return
        FILE_URL=$(echo "$PAGE" | grep_http_header_location)

        # check for link redirection (HTTP error 301)
        if [ "${FILE_URL:0:1}" = '/' ]; then
            PAGE=$(curl -i -b "$COOKIEFILE" "${BASE_URL}$FILE_URL") || return
            FILE_URL=$(echo "$PAGE" | grep_http_header_location)
        fi

        # Account download method set to "Automatisch"
        # HTTP HEAD request discarded, can't read "Content-Disposition" header
        if [ -n "$FILE_URL" ]; then

            # Only solution to get filename
            PAGE=$(curl -L "$URL") || return

            echo "$FILE_URL"
            echo "$PAGE" | parse 'dl_first_filename' '			\([^<]*\)' 1
            return 0
        fi

        echo "$PAGE" | parse_attr 'Orange_Link' 'href'
        echo "$PAGE" | parse '<h2>download:' ': \([^<]*\)'
        return 0
    fi

    PAGE=$(curl --location -c "$COOKIEFILE" "$URL") || return

    # This file can be only downloaded by Premium users in fact of its file size
    if match 'This file is only for Premium Users' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    WAIT_URL=$(echo "$PAGE" | parse_attr_quiet '<div class="Free_dl">' 'href')

    test "$WAIT_URL" || return $ERR_LINK_DEAD
    test "$CHECK_LINK" && return 0

    WAIT_URL="$BASE_URL/${WAIT_URL//&amp;/&}"
    WAIT_HTML=$(curl -b "$COOKIEFILE" --location --referer "$URL" "$WAIT_URL") || return
    WAIT_TIME=$(echo "$WAIT_HTML" | parse_quiet 'type="text/javascript">countdown' \
            "countdown(\([[:digit:]]*\),'change()')")

    wait $((WAIT_TIME / 100)) seconds || return

    # 74x29 jpeg file
    CAPTCHA_URL=$(echo "$WAIT_HTML" | parse_attr '<img style="vertical-align' 'src') || return
    CAPTCHA_IMG=$(create_tempfile '.jpg') || return

    # Get new image captcha (cookie is mandatory)
    curl -b "$COOKIEFILE" "$BASE_URL/$CAPTCHA_URL" -o "$CAPTCHA_IMG" || return

    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG" digits 4) || return
    { read WORD; read ID; } <<<"$WI"
    rm -f "$CAPTCHA_IMG"

    if [ "${#WORD}" -lt 4 ]; then
        captcha_nack $ID
        log_debug "captcha length invalid"
        return $ERR_CAPTCHA
    elif [ "${#WORD}" -gt 4 ]; then
        WORD="${WORD:0:4}"
    fi

    log_debug "decoded captcha: $WORD"

    # Send (post) form
    local DOWNLOAD_FORM FORM_URL FORM_FID WAIT_HTML2
    DOWNLOAD_FORM=$(grep_form_by_order "$WAIT_HTML" 1)
    FORM_URL=$(echo "$DOWNLOAD_FORM" | parse_form_action) || return
    FORM_FID=$(echo "$DOWNLOAD_FORM" | parse_form_input_by_name 'file_id') || return

    WAIT_HTML2=$(curl -b "$COOKIEFILE" \
        -d "start=" \
        -d "file_id=$FORM_FID" \
        -d "captcha_check=$CAPTCHA" \
        "$BASE_URL/$FORM_URL") || return

    if match 'class="InPage_Error"' "$WAIT_HTML2"; then
        captcha_nack $ID
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug "correct captcha"

    WAIT_TIME2=$(echo "$WAIT_HTML2" | parse_quiet 'type="text/javascript">countdown' \
            "countdown(\([[:digit:]]*\),'change()')")

    # <!--./share/templates/download_limit.tpl-->
    # <!--./share/templates/download_wait.tpl-->
    if [[ $WAIT_TIME2 -gt 10000 ]]; then
        log_debug "Download limit reached!"
        echo $((WAIT_TIME2 / 100))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Suppress this wait will lead to a 400 http error (bad request)
    wait $((WAIT_TIME2 / 100)) seconds || return

    FILENAME=$(echo "$WAIT_HTML2" | \
        parse_quiet '<h2>[Dd]ownload:' '<h2>[Dd]ownload:[[:space:]]*\([^<]*\)')

    # If filename is truncated, take the one from url
    if [ "${#FILENAME}" -ge 57 -a '..' = "${FILENAME:(-2):2}" ]; then
        if match '\.htm$' "$URL"; then
            local FILENAME2=$(basename_file "$URL")
            match '^datei' "$FILENAME2" || \
                FILENAME=$(echo "${FILENAME2%.*}" | uri_decode)
        fi
    fi

    FILE_URL=$(echo "$WAIT_HTML2" | \
        parse '<a class="Orange_Link"' 'Link" href="\(http[^"]*\)')

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to netload.in
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: netload.in download link (delete link)
#
# http://api.netload.in/index.php?id=3
# Note: Password protected archives upload is not managed here.
netload_in_upload() {
    eval "$(process_options netload_in "$MODULE_NETLOAD_IN_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL="http://netload.in"

    local AUTH_CODE UPLOAD_SERVER EXTRA_PARAMS

    if test "$AUTH"; then
        netload_in_premium_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return
        curl -b "$COOKIEFILE" --data 'get=Get Auth Code' -o /dev/null 'http://www.netload.in/index.php?id=56'

        AUTH_CODE=$(curl -b "$COOKIEFILE" 'http://www.netload.in/index.php?id=56' | \
            parse 'Your Auth Code' ';">\([^<]*\)') || return
        log_debug "auth=$AUTH_CODE"

        local USER PASSWORD
        split_auth "$AUTH" USER PASSWORD || return

        EXTRA_PARAMS="-F user_id=$USER -F user_password=$PASSWORD"
    else
        AUTH_CODE="LINUX"
        EXTRA_PARAMS=
    fi

    UPLOAD_SERVER=$(curl 'http://api.netload.in/getserver.php') || return

    PAGE=$(curl_with_log $EXTRA_PARAMS \
        --form-string "auth=$AUTH_CODE" \
        -F "modus=file_upload" \
        -F "file_link=@$FILE;filename=$DESTFILE" \
        "$UPLOAD_SERVER") || return

    # Expected result:
    # return_code;filename;filesize;download_link;delete_link
    IFS=';' read RETCODE FILENAME FILESIZE DL DEL <<< "$PAGE"

    case "$RETCODE" in
        UPLOAD_OK)
            echo "$DL"
            echo "$DEL"
            return 0
            ;;
        rar_password)
            log_error "Archive is password protected"
            ;;
        unknown_user_id|wrong_user_password|no_user_password)
            log_error "bad login and/or password ($RETCODE)"
            return $ERR_LOGIN_FAILED
            ;;
        unknown_auth|prepare_failed)
            log_error "unexpected result ($RETCODE)"
            ;;
    esac

    return $ERR_FATAL
}

# List multiple netload.in links
# $1: netfolder.in link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
netload_in_list() {
    eval "$(process_options netload_in "$MODULE_NETLOAD_IN_LIST_OPTIONS" "$@")"

    local URL=$1
    local PAGE LINKS NAMES

    if ! match '/folder' "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    PAGE=$(curl "$URL" | break_html_lines_alt) || return

    # Folder can have a password
    if match '<div id="Password">' "$PAGE"; then
        log_debug "Password-protected folder"
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi
        PAGE=$(curl --data "password=$LINK_PASSWORD" "$URL" | \
            break_html_lines_alt) || return

        #<div class="InPage_Error"><pre>&bull; Passwort ist ung&uuml;ltig!<br/></pre></div>
        match '"InPage_Error">' "$PAGE" && \
            return $ERR_LINK_PASSWORD_REQUIRED
    fi

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'Link_[[:digit:]]' 'href')
    test "$LINKS" || return $ERR_LINK_DEAD

    NAMES=$(echo "$PAGE" | parse_all 'Link_[[:digit:]]' '^\([^<]*\)' 2)

    list_submit "$LINKS" "$NAMES" || return
}
