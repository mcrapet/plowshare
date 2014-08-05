# Plowshare netload.in module
# Copyright (c) 2010-2013 Plowshare team
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

MODULE_NETLOAD_IN_REGEXP_URL='https\?://\(www\.\)\?net\(load\|folder\)\.in/'

MODULE_NETLOAD_IN_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,Premium account"
MODULE_NETLOAD_IN_DOWNLOAD_RESUME=no
MODULE_NETLOAD_IN_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_NETLOAD_IN_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_NETLOAD_IN_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,Premium account"
MODULE_NETLOAD_IN_UPLOAD_REMOTE_SUPPORT=no

MODULE_NETLOAD_IN_LIST_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Used for password-protected folder"
MODULE_NETLOAD_IN_LIST_HAS_SUBFOLDERS=yes

MODULE_NETLOAD_IN_PROBE_OPTIONS=""

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
        log_debug 'bad login and/or password'
        return $ERR_LOGIN_FAILED
    fi
}

# Static function. Retrieve file information using official API
# $1: file id
# $2: return md5 (0 or 1)
netload_in_infos() {
    # Plowshare Auth Code
    local -r AUTH_CODE='ec3vfSuAXoHVQxA816hsKGdOCbQ6it9N'
    curl -d "auth=$AUTH_CODE" -d "file_id=$1" -d 'bz=1' -d "md5=$2" \
        'https://api.netload.in/info.php'
}

# Output a netload.in file download URL
# $1: cookie file
# $2: netload.in url
# stdout: real file download link
netload_in_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(echo "$2" | replace 'www.' '')
    local -r BASE_URL='http://netload.in'
    local FILE_ID RESPONSE FILE_NAME
    local PAGE WAIT_URL WAIT_HTML WAIT_TIME CAPTCHA_URL CAPTCHA_IMG FILE_URL

    # Get filename using API
    FILE_ID=$(echo "$URL" | parse . '/datei\([[:alnum:]]\+\)[/.]') || return
    log_debug "File ID: '$FILE_ID'"

    # file ID, filename, size, status
    RESPONSE=$(netload_in_infos "$FILE_ID" 0) || return
    FILE_NAME=${RESPONSE#*;}
    FILE_NAME=${FILE_NAME%%;*}

    if [ -n "$AUTH" ]; then
        netload_in_premium_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
        MODULE_NETLOAD_IN_DOWNLOAD_RESUME=yes

        PAGE=$(curl -i -b "$COOKIE_FILE" "$URL") || return
        FILE_URL=$(echo "$PAGE" | grep_http_header_location)

        # check for link redirection (HTTP error 301)
        if [ "${FILE_URL:0:1}" = '/' ]; then
            PAGE=$(curl -i -b "$COOKIE_FILE" "${BASE_URL}$FILE_URL") || return
            FILE_URL=$(echo "$PAGE" | grep_http_header_location)
        fi

        # Account download method set to "Automatisch"
        # HTTP HEAD request discarded, can't read "Content-Disposition" header
        if [ -n "$FILE_URL" ]; then
            echo "$FILE_URL"
            echo "$FILE_NAME"
            return 0
        fi

        parse_attr 'Orange_Link' 'href' <<< "$PAGE" || return
        echo "$FILE_NAME"
        return 0
    fi

    PAGE=$(curl --location -c "$COOKIE_FILE" "$URL") || return

    # This file can be only downloaded by Premium users in fact of its file size
    if match 'This file is only for Premium Users' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    WAIT_URL=$(echo "$PAGE" | parse_attr_quiet '<div class="Free_dl">' 'href')

    test "$WAIT_URL" || return $ERR_LINK_DEAD

    WAIT_URL="$BASE_URL/${WAIT_URL//&amp;/&}"
    WAIT_HTML=$(curl -b "$COOKIE_FILE" --location --referer "$URL" "$WAIT_URL") || return
    WAIT_TIME=$(echo "$WAIT_HTML" | parse_quiet 'type="text/javascript">countdown' \
            "countdown(\([[:digit:]]*\),'change()')")

    wait $((WAIT_TIME / 100)) seconds || return

    # 74x29 jpeg file
    CAPTCHA_URL=$(echo "$WAIT_HTML" | parse_attr '<img style="vertical-align' 'src') || return
    CAPTCHA_IMG=$(create_tempfile '.jpg') || return

    # Get new image captcha (cookie is mandatory)
    curl -b "$COOKIE_FILE" "$BASE_URL/$CAPTCHA_URL" -o "$CAPTCHA_IMG" || return

    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG" digits 4) || return
    { read WORD; read ID; } <<<"$WI"
    rm -f "$CAPTCHA_IMG"

    if [ "${#WORD}" -lt 4 ]; then
        captcha_nack $ID
        log_debug 'captcha length invalid'
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

    WAIT_HTML2=$(curl -b "$COOKIE_FILE" \
        -d 'start=' \
        -d "file_id=$FORM_FID" \
        -d "captcha_check=$WORD" \
        "$BASE_URL/$FORM_URL") || return

    if match 'class="InPage_Error"' "$WAIT_HTML2"; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'correct captcha'

    WAIT_TIME2=$(echo "$WAIT_HTML2" | parse_quiet 'type="text/javascript">countdown' \
            "countdown(\([[:digit:]]*\),'change()')")

    # <!--./share/templates/download_limit.tpl-->
    # <!--./share/templates/download_wait.tpl-->
    if [[ $WAIT_TIME2 -gt 10000 ]]; then
        log_debug 'Download limit reached!'
        echo $((WAIT_TIME2 / 100))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Suppress this wait will lead to a 400 http error (bad request)
    wait $((WAIT_TIME2 / 100)) seconds || return

    FILE_URL=$(echo "$WAIT_HTML2" | \
        parse '<a class="Orange_Link"' 'Link" href="\(http[^"]*\)')

    echo "$FILE_URL"
    echo "$FILE_NAME"
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
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL="http://www.netload.in"

    local AUTH_CODE UPLOAD_SERVER EXTRA_PARAMS

    if test "$AUTH"; then
        netload_in_premium_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
        curl -b "$COOKIE_FILE" --data 'get=Get Auth Code' -o /dev/null "$BASE_URL/index.php?id=56"

        AUTH_CODE=$(curl -b "$COOKIE_FILE" "$BASE_URL/index.php?id=56" | \
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
        -F 'modus=file_upload' \
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
            log_error 'Archive is password protected'
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
    local URL=$1
    local PAGE LINKS NAMES

    if ! match '/folder' "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    PAGE=$(curl "$URL" | break_html_lines_alt) || return

    # Folder can have a password
    if match '<div id="Password">' "$PAGE"; then
        log_debug 'Password-protected folder'
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

# Probe a download URL
# $1: cookie file (unused here)
# $2: Netfolder.in url
# $3: requested capability list
# stdout: 1 capability per line
netload_in_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local RESPONSE REQ_OUT FILE_ID FILE_NAME FILE_SIZE FILE_HASH STATUS

    if [[ "$URL" = */folder* ]]; then
        log_error 'This is a folder. Please use plowlist.'
        return $ERR_FATAL
    fi

    FILE_ID=$(echo "$2" | parse . '/datei\([[:alnum:]]\+\)[/.]') || return
    log_debug "File ID: '$FILE_ID'"

    RESPONSE=$(netload_in_infos "$FILE_ID" 1) || return

    if [ "$RESPONSE" = 'unknown_auth' ]; then
        log_error 'API key invalid. Please report this issue!'
        return $ERR_FATAL
    fi

    # file ID, filename, size, status, MD5
    IFS=';' read FILE_ID FILE_NAME FILE_SIZE STATUS FILE_HASH <<< "$RESPONSE"

    [ "$STATUS" = 'online' ] || return $ERR_LINK_DEAD
    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        [ -n "$FILE_NAME" ] && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        [ -n "$FILE_SIZE" ] && echo "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *h* ]]; then
        [ -n "$FILE_HASH" ] && echo "$FILE_HASH" && REQ_OUT="${REQ_OUT}h"
    fi

    echo $REQ_OUT
}
