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

MODULE_LETITBIT_REGEXP_URL="http://\(\(www\|u[[:digit:]]\{8\}\)\.\)\?letitbit\.net/"

MODULE_LETITBIT_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account"
MODULE_LETITBIT_DOWNLOAD_RESUME=yes
MODULE_LETITBIT_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_LETITBIT_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_LETITBIT_UPLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account (mandatory)"
MODULE_LETITBIT_UPLOAD_REMOTE_SUPPORT=no

MODULE_LETITBIT_LIST_OPTIONS=""

MODULE_LETITBIT_DELETE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
letitbit_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE ERR TYPE EMAIL

    LOGIN_DATA='act=login&login=$USER&password=$PASSWORD'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/index.php" -b 'lang=en') || return

    # Note: Cookies "pas" + "log" (=login name) get set on successful login
    ERR=$(echo "$PAGE" | parse_tag_quiet 'error-text' 'span')

    if [ -n "$ERR" ]; then
        log_error "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    # Determine account type
    PAGE=$(curl -b "$COOKIE_FILE" -H 'X-Requested-With: XMLHttpRequest' \
        -d 'act=get_attached_passwords' \
        "$BASE_URL/ajax/get_attached_passwords.php") || return

    # There are no attached premium accounts found
    if match 'no attached premium accounts' "$PAGE"; then
        TYPE='free'

    # Note: Contains a table of associated premium codes
    elif match '^[[:space:]]*<th>Premium account</th>' "$PAGE"; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    EMAIL=$(parse_cookie 'log' < "$COOKIE_FILE" | uri_decode) || return
    log_debug "Successfully logged in as $TYPE member '$EMAIL'"

    echo "$TYPE"
}

# Output a file URL to download from Letitbit.net
# $1: cookie file
# $2: letitbit url
# stdout: real file download link
#         file name
letitbit_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://letitbit.net'
    local PAGE URL ACCOUNT SERVER WAIT CONTROL FILE_NAME
    local FORM_HTML FORM_REDIR FORM_UID5 FORM_UID FORM_ID FORM_LIVE FORM_SEO
    local FORM_NAME FORM_PIN FORM_REAL_UID FORM_REAL_NAME FORM_HOST FORM_SERVER
    local FORM_SIZE FORM_FILE_ID FORM_INDEX FORM_DIR FORM_ODIR FORM_DESC
    local FORM_LSA FORM_PAGE FORM_SKYMONK FORM_MD5 FORM_REAL_UID_FREE
    local FORM_SHASH FORM_SPIN

    # server redirects "simple links" to real download server
    #
    # simple: http://letitbit.net/download/...
    #         http://www.letitbit.net/download/...
    # real:   http://u29043481.letitbit.net/download/...
    URL=$(curl --head "$2" | grep_http_header_location_quiet "PAGE")
    [ -n "$URL" ] || URL=$2
    LINK_BASE_URL=${URL%%/download/*}

    if [ -n "$AUTH" ]; then
         ACCOUNT=$(letitbit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Note: Premium users are redirected to a download page
    PAGE=$(curl --location -b "$COOKIE_FILE" -b 'lang=en' "$URL") || return

    if match 'File not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    [ -n "$CHECK_LINK" ] && return 0

    if [ "$ACCOUNT" = 'premium' ]; then
        local FILE_LINKS

        FILE_NAME=$(echo "$PAGE" | parse_tag 'File:' 'a') || return
        FILE_LINKS=$(echo "$PAGE" | \
            parse_all_attr 'Link to the file download' 'href') || return

        # Note: The page performs some kind of verification on all links, but
        #       we try to do without this for now and just use the 1st link.
        log_debug "All Links: $FILE_LINKS"

        echo "$FILE_LINKS" | first_line
        echo "$FILE_NAME"
        return 0
    fi

    # anon/free account download
    FORM_HTML=$(grep_form_by_id "$PAGE" 'ifree_form') || return
    FORM_REDIR=$(echo "$FORM_HTML" | parse_form_input_by_name 'redirect_to_pin') || return
    FORM_UID5=$(echo "$FORM_HTML" | parse_form_input_by_name 'uid5') || return
    FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'uid') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_LIVE=$(echo "$FORM_HTML" | parse_form_input_by_name 'live') || return
    FORM_SEO=$(echo "$FORM_HTML" | parse_form_input_by_name 'seo_name') || return
    FORM_NAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'name') || return
    FORM_PIN=$(echo "$FORM_HTML" | parse_form_input_by_name 'pin') || return
    FORM_REAL_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'realuid') || return
    FORM_REAL_NAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'realname') || return
    FORM_HOST=$(echo "$FORM_HTML" | parse_form_input_by_name 'host') || return
    FORM_SERVER=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'ssserver')
    FORM_SIZE=$(echo "$FORM_HTML" | parse_form_input_by_name 'sssize') || return
    FORM_FILE_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'file_id') || return
    FORM_INDEX=$(echo "$FORM_HTML" | parse_form_input_by_name 'index') || return
    FORM_DIR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'dir')
    FORM_ODIR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'optiondir')
    FORM_DESC=$(echo "$FORM_HTML" | parse_form_input_by_name 'desc') || return
    FORM_LSA=$(echo "$FORM_HTML" | parse_form_input_by_name 'lsarrserverra') || return
    FORM_PAGE=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'page')
    FORM_SKYMONK=$(echo "$FORM_HTML" | parse_form_input_by_name 'is_skymonk') || return
    FORM_MD5=$(echo "$FORM_HTML" | parse_form_input_by_name 'md5crypt') || return
    FORM_REAL_UID_FREE=$(echo "$FORM_HTML" | parse_form_input_by_name 'realuid_free') || return
    FORM_SHASH=$(echo "$FORM_HTML" | parse_form_input_by_name 'slider_hash') || return
    FORM_SPIN=$(echo "$FORM_HTML" | parse_form_input_by_name 'slider_pin') || return

    FILE_NAME=$(echo "$PAGE" | parse 'fileName =' '"\(.\+\)"') || return

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' -c "$COOKIE_FILE"               \
        -d "redirect_to_pin=$FORM_REDIR" -d "uid5=$FORM_UID5"                  \
        -d "uid=$FORM_UID"      -d "id=$FORM_ID"     -d "live=$FORM_LIVE"      \
        -d "seo_name=$FORM_SEO" -d "name=$FORM_NAME" -d "pin=$FORM_PIN"        \
        -d "realuid=$FORM_REAL_UID"      -d "realname=$FORM_REAL_NAME"         \
        -d "host=$FORM_HOST"             -d "ssserver=$FORM_SERVER"            \
        -d "sssize=$FORM_SIZE"           -d "file_id=$FORM_FILE_ID"            \
        -d "index=$FORM_INDEX"  -d "dir=$FORM_DIR"   -d "optiondir=$FORM_ODIR" \
        -d "desc=$FORM_DESC"             -d "lsarrserverra=$FORM_LSA"          \
        -d "page=$FORM_PAGE"             -d "is_skymonk=$FORM_SKYMONK"         \
        -d "md5crypt=$FORM_MD5"          -d "realuid_free=$FORM_REAL_UID_FREE" \
        -d "slider_hash=$FORM_SHASH"     -d "slider_pin=$FORM_SPIN"            \
        "$LINK_BASE_URL/download3.php") || return

    # Note: Site adds an additional "control field" to the usual ReCaptcha stuff
    CONTROL=$(echo "$PAGE" | parse 'var[[:space:]]\+recaptcha_control_field' \
        "=[[:space:]]\+'\([^']\+\)';") || return

    WAIT=$(echo "$PAGE" | parse_tag 'Wait for Your turn' 'span') || return
    wait $((WAIT + 1)) || return

    # dummy "-d" to force a POST request
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' -d '' \
        -H 'X-Requested-With: XMLHttpRequest' \
        "$LINK_BASE_URL/ajax/download3.php") || return

    if [ "$PAGE" != '1' ]; then
        # daily limit reached!?
        log_error "Unexpected response: $PAGE"
        return $ERR_FATAL
    fi

    # Solve recaptcha
    local PUBKEY WCI CHALLENGE WORD CONTROL ID
    PUBKEY='6Lc9zdMSAAAAAF-7s2wuQ-036pLRbM0p8dDaQdAM'
    WCI=$(recaptcha_process $PUBKEY)
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    # Note: "recaptcha_control_field" *must* be encoded properly
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en'    \
        --referer "$LINK_BASE_URL/download3.php"  \
        -H 'X-Requested-With: XMLHttpRequest'     \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD"       \
        --data-urlencode "recaptcha_control_field=$CONTROL" \
        "$LINK_BASE_URL/ajax/check_recaptcha.php") || return

    # Server response should contain multiple URLs if successful
    if ! match 'http' "$PAGE"; then
        if [ "$PAGE" = 'error_wrong_captcha' ]; then
            log_error 'Wrong captcha'
            captcha_nack "$ID"
            return $ERR_CAPTCHA

        elif [ "$PAGE" = 'error_free_download_blocked' ]; then
            # We'll take it literally and wait till the next day
            local HOUR MIN TIME

            # Get current UTC time, prevent leading zeros
            TIME=$(date -u +'%k:%M') || return
            HOUR=${TIME%:*}
            MIN=${TIME#*:}

            log_error 'Daily limit (1 download per day) reached.'
            echo $(( ((23 - HOUR) * 60 + (61 - ${MIN#0}) ) * 60 ))
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        log_error "Unexpected remote error: $PAGE"
        return $ERR_FATAL
    fi

    log_debug 'Correct captcha'
    captcha_ack "$ID"

    # Response contains multiple possible download links, we just pick the first
    echo "$PAGE" | parse . '"\(http:[^"]\+\)"' || return
    echo "$FILE_NAME"
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

    # Login (don't care for account type)
    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS
    letitbit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" > /dev/null || return

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
    PAGE=$(curl_with_log -b "$COOKIE_FILE" -b 'lang=en' \
        -F "MAX_FILE_SIZE=$MAX_SIZE" \
        -F "owner=$FORM_OWNER"       \
        -F "pin=$FORM_PIN"           \
        -F "base=$FORM_BASE"         \
        -F "host=$FORM_HOST"         \
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

# Delete a file on Letitbit.net
# $1: cookie file
# $2: letitbit.net (delete) link
letitbit_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://letitbit.net'
    local DEL_PART PAGE

    # http://letitbit.net/download/delete15623193_0be902ba49/70662.717a170fc1bf0620a7f62fde1975/worl.html
    if ! match 'download/delete' "$URL"; then
        log_error 'This is not a delete link.'
        return $ERR_FATAL
    fi

    # Check (manually) if file exists
    # remove "delete15623193_0be902ba49/" to get normal download link
    DEL_PART=$(echo "$URL" | parse . '\(delete[^/]\+\)') || return
    PAGE=$(curl -L -b 'lang=en' "${URL/$DEL_PART\//}") || return

    if match 'File not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    curl -L -b 'lang=en' -c "$COOKIE_FILE" -o /dev/null "$URL" || return

    # Solve recaptcha
    local PUBKEY WCI CHALLENGE WORD CONTROL ID
    PUBKEY='6Lc9zdMSAAAAAF-7s2wuQ-036pLRbM0p8dDaQdAM'
    WCI=$(recaptcha_process $PUBKEY)
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    PAGE=$(curl --referer "$URL" -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest'      \
        -d "recaptcha_challenge_field=$CHALLENGE"  \
        -d "recaptcha_response_field=$WORD"        \
        "$BASE_URL/ajax/check_recaptcha2.php") || return

    case "$PAGE" in
        ok)
            captcha_ack "$ID"
            return 0
            ;;
        error_wrong_captcha)
            log_error 'Wrong captcha'
            captcha_nack "$ID"
            return $ERR_CAPTCHA
            ;;
        *)
            log_error "Unexpected response: $PAGE"
            return $ERR_FATAL
            ;;
    esac
}

# List an Letitbit.net shared file folder URL
# $1: letitbit.net folder url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
letitbit_list() {
    local URL=$1
    local PAGE LINKS NAMES

    # check whether it looks like a folder link
    if ! match "${MODULE_LETITBIT_REGEXP_URL}folder/" "$URL"; then
        log_error "This is not a directory list."
        return $ERR_FATAL
    fi

    test "$2" && log_debug "letitbit does not display sub folders"

    PAGE=$(curl -L "$URL") || return

    LINKS=$(echo "$PAGE" | parse_all_attr 'target="_blank"' 'href')
    NAMES=$(echo "$PAGE" | parse_all_tag 'target="_blank"' 'font')

    test "$LINKS" || return $ERR_LINK_DEAD

    list_submit "$LINKS" "$NAMES" || return
}
