#!/bin/bash
#
# mediafire.com module
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

MODULE_MEDIAFIRE_REGEXP_URL="http://\(www\.\)\?mediafire\.com/"

MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS="
LINK_PASSWORD,p:,link-password:,PASSWORD,Used in password-protected files"
MODULE_MEDIAFIRE_DOWNLOAD_RESUME=yes
MODULE_MEDIAFIRE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_MEDIAFIRE_UPLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free account"
MODULE_MEDIFIARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_MEDIAFIRE_LIST_OPTIONS=""

# Static function
get_ofuscated_link() {
    local VAR=$1
    local I N C R

    I=0
    N=${#VAR}
    while (( I < N )); do
        C=$((16#${VAR:$I:2} + 0x18))
        R="$R"$(printf \\$(($C/64*100+$C%64/8*10+$C%8)))
        (( I += 2 ))
    done
    echo "$R"
}

# Output a mediafire file download URL
# $1: cookie file
# $2: mediafire.com url
# stdout: real file download link
mediafire_download() {
    eval "$(process_options mediafire "$MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$(echo "$2" | replace '/download.php?' '?')
    local LOCATION PAGE FILE_URL FILENAME JSON JS_VAR

    LOCATION=$(curl --head "$URL" | grep_http_header_location_quiet) || return

    if match '^http://download' "$LOCATION"; then
        log_debug "direct download"
        echo "$LOCATION"
        return 0
    elif match 'errno=999$' "$LOCATION"; then
        return $ERR_LINK_NEED_PERMISSIONS
    elif match 'errno=320$' "$LOCATION"; then
        return $ERR_LINK_DEAD
    elif match 'errno=378$' "$LOCATION"; then
        return $ERR_LINK_DEAD
    elif match 'errno=' "$LOCATION"; then
        log_error "site redirected with an unknown error"
        return $ERR_FATAL
    fi

    PAGE=$(curl -L -c "$COOKIEFILE" "$URL" | break_html_lines) || return

    if ! match 'class="download_file_title"' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi
    test "$CHECK_LINK" && return 0

    # reCaptcha
    if match '<textarea name="recaptcha_challenge_field"' "$PAGE"; then

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LextQUAAAAAALlQv0DSHOYxqF3DftRZxA5yebEe'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        PAGE=$(curl -L -b "$COOKIEFILE" --data \
            "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" \
            -H "X-Requested-With: XMLHttpRequest" --referer "$URL" \
            "$URL" | break_html_lines) || return

        # You entered the incorrect keyword below, please try again!
        if match 'incorrect keyword' "$PAGE"; then
            captcha_nack $ID
            log_error "Wrong captcha"
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug "correct captcha"
    fi

    # Check for password protected link
    if match 'name="downloadp"' "$PAGE"; then
        log_debug "File is password protected"
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD="$(prompt_for_password)" || return
        fi
        PAGE=$(curl -L --post301 -b "$COOKIEFILE" \
            --data "downloadp=$LINK_PASSWORD" "$URL" | break_html_lines) || return
        if match 'name="downloadp"' "$PAGE"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        fi
    fi

    JS_VAR=$(echo "$PAGE" |  parse 'function[[:space:]]*_' '"\([^"]\+\)";' 1) || return
    FILE_URL=$(get_ofuscated_link "$JS_VAR" | parse_attr href) || return

    FILENAME=$(curl -I "$FILE_URL" | grep_http_header_content_disposition) || return

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to mediafire
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: mediafire.com download link
mediafire_upload() {
    eval "$(process_options mediafire "$MODULE_MEDIAFIRE_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local FILE=$2
    local DESTFILE=$3
    local SZ=$(get_filesize "$FILE")
    local BASE_URL='http://www.mediafire.com'
    local XML UKEY USER FOLDER_KEY MFUL_CONFIG UPLOAD_KEY QUICK_KEY N

    if [ -n "$AUTH_FREE" ]; then
        # Get ukey cookie entry (mandatory)
        curl -c "$COOKIEFILE" -o /dev/null "$BASE_URL"

        # HTTPS login (login_remember=on not required)
        LOGIN_DATA='login_email=$USER&login_pass=$PASSWORD&submit_login=Login+to+MediaFire'
        LOGIN_RESULT=$(post_login "$AUTH_FREE" "$COOKIEFILE" "$LOGIN_DATA" \
            'http://www.mediafire.com/dynamic/login.php?popup=1' -b "$COOKIEFILE") || return

        # If successful, two entries are added into cookie file: user and session
        SESSION=$(parse_cookie_quiet 'session' < "$COOKIEFILE")
        if [ -z "$SESSION" ]; then
            log_error "login process failed"
            return $ERR_FATAL
        fi
    else
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    # File size limit check
    if [ "$SZ" -gt 209715200 ]; then
        log_debug "file is bigger than 200MB"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    log_debug "Get uploader configuration"
    XML=$(curl -b "$COOKIEFILE" "$BASE_URL/basicapi/uploaderconfiguration.php?$$" | break_html_lines) ||
            { log_error "Couldn't upload file!"; return $ERR_FATAL; }

    UKEY=$(echo "$XML" | parse_tag_quiet ukey)
    USER=$(echo "$XML" | parse_tag_quiet user)
    FOLDER_KEY=$(echo "$XML" | parse_tag_quiet folderkey)
    MFUL_CONFIG=$(echo "$XML" | parse_tag_quiet MFULConfig)

    log_debug "folderkey: $FOLDER_KEY"
    log_debug "ukey: $UKEY"
    log_debug "MFULConfig: $MFUL_CONFIG"

    if [ -z "$UKEY" -o -z "$FOLDER_KEY" -o -z "$MFUL_CONFIG" -o -z "$USER" ]; then
        log_error "Can't parse uploader configuration!"
        return $ERR_FATAL
    fi

    # HTTP header "Expect: 100-continue" seems to confuse server
    # Note: -b "$COOKIEFILE" is not required here
    XML=$(curl_with_log -0 \
        -F "Filename=$DESTFILE" \
        -F "Upload=Submit Query" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        --user-agent "Shockwave Flash" \
        --referer "$BASE_URL/basicapi/uploaderconfiguration.php?$$" \
        "$BASE_URL/douploadtoapi/?type=basic&ukey=$UKEY&user=$USER&uploadkey=$FOLDER_KEY&upload=0") || return

    # Example of answer:
    # <?xml version="1.0" encoding="iso-8859-1"?>
    # <response>
    #  <doupload>
    #   <result>0</result>
    #   <key>sf22seu6p7d</key>
    #  </doupload>
    # </response>
    UPLOAD_KEY=$(echo "$XML" | parse_tag_quiet key)

    # Get error code (<result>)
    if [ -z "$UPLOAD_KEY" ]; then
        local ERR_CODE=$(echo "$XML" | parse_tag_quiet result)
        log_error "mediafire internal error: ${ERR_CODE:-n/a}"
        return $ERR_FATAL
    fi

    log_debug "polling for status update (with key $UPLOAD_KEY)"

    for N in 4 3 3 2 2 2; do
        wait $N seconds || return

        XML=$(curl "$BASE_URL/basicapi/pollupload.php?key=$UPLOAD_KEY&MFULConfig=$MFUL_CONFIG") || return

        # <description>Verifying File</description>
        if match '<description>No more requests for this key</description>' "$XML"; then
            QUICK_KEY=$(echo "$XML" | parse_tag_quiet quickkey)

            echo "$BASE_URL/?$QUICK_KEY"
            return 0
        fi
    done

    log_error "Can't get quick key!"
    return $ERR_FATAL
}

# List a mediafire shared file folder URL
# $1: mediafire folder url (http://www.mediafire.com/?sharekey=...)
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
mediafire_list() {
    local URL=$1
    local REC=${2:-no}
    local LOCATION DATA QUICKKEY NUM LINKS NAMES

    if match '/?sharekey=' "$URL"; then
        LOCATION=$(curl --head "$URL" | grep_http_header_location) || return
        if ! match '^/' "$LOCATION"; then
            log_error "not a shared folder"
            return $ERR_FATAL
        fi
        URL="http://www.mediafire.com$LOCATION"
    fi

    QUICKKEY=$(echo "$URL" | parse 'mediafire\.com/?' '?\([^&"]*\)')
    log_debug "quickkey: $QUICKKEY"

    # remark: response_format=json is also possible
    URL="http://www.mediafire.com/api/folder/get_info.php?recursive=$REC&response_format=xml&version=1"
    DATA=$(curl --get \
        -d "r=$(random a 6)" \
        -d "folder_key=$QUICKKEY" \
        "$URL" | break_html_lines) || return

    NUM=$(echo "$DATA" | parse_tag_quiet file_count) || NUM=0
    log_debug "There is/are $NUM file(s) in the folder"

    test "$NUM" -eq '0' && return $ERR_LINK_DEAD

    NAMES=$(echo "$DATA" | parse_all_tag filename)
    LINKS=$(echo "$DATA" | parse_all_tag quickkey)

    # Add prefix to each line (FIXME: should find a better solution)
    LINKS=$(sed -e 's=^=http://www.mediafire.com/\?=' <<< "$LINKS")

    list_submit "$LINKS" "$NAMES" || return
}
