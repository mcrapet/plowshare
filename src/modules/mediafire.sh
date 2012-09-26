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
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_MEDIAFIRE_DOWNLOAD_RESUME=yes
MODULE_MEDIAFIRE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_MEDIAFIRE_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
FOLDER,,folder,s=FOLDER,Folder to upload files into
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
PRIVATE_FILE,,private,,Do not show file in folder view"
MODULE_MEDIFIARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_MEDIAFIRE_LIST_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
mediafire_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local -r ENC_BASE_URL=$(uri_encode_strict <<< "$BASE_URL/")
    local LOGIN_DATA PAGE CODE NAME

    # Make sure we have "ukey" cookie (mandatory)
    curl -c "$COOKIE_FILE" -o /dev/null "$BASE_URL"

    # Note: "login_remember=on" not required

    LOGIN_DATA='login_email=$USER&login_pass=$PASSWORD&submit_login=Login+to+MediaFire'
    PAGE=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
        "${BASE_URL/#http/https}/dynamic/login.php?popup=1" \
        -b "$COOKIE_FILE") || return

    # Note: Cookies "user" and "session" get set on successful login, "skey" is changed"
    CODE=$(echo "$PAGE" | parse 'var et' 'var et= \(-\?[[:digit:]]\+\);') || return
    NAME=$(echo "$PAGE" | parse 'var fp' "var fp='\([^']\+\)';") || return

    # Check for errors
    # Note: All error codes are explained in page returned by server.
    if [ $CODE -ne 15 ]; then
        log_debug "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    log_debug "Successfully logged in as member '$NAME'"
}

# Retrieve current session key
# $1: cookie file (logged into account)
# $2: base URL
# stdout: session key
mediafire_extract_session_key() {
    local PAGE KEY

    # Though we cannot login via the official API (requires app ID) we can
    # extract the session ID and use most of the API with that :-)
    PAGE=$(curl -b "$1" "$2/myfiles.php") || return
    KEY=$(echo "$PAGE" | \
        parse 'window.tH.YQ' 'window.tH.YQ("\([[:xdigit:]]\+\)",') || return

    log_debug "Session key: '$KEY'"
    echo "$KEY"
}

# Check if specified folder name is valid.
# When multiple folders wear the same name, first one is taken.
# $1: session key
# $2: base URL
# $3: folder name selected by user
# stdout: folder key
mediafire_check_folder() {
    local -r SESSION_KEY=$1
    local -r BASE_URL=$2
    local -r NAME=$3
    local -a FOLDER_NAMES # all folder names encountered
    local -a FOLDER_KEYS # all folder keys encountered
    local XML IDX LINE NAMES KEYS

    # Get root folder to initialize folder traversal
    XML=$(curl -d "session_token=$SESSION_KEY" \
        "$BASE_URL/api/folder/get_info.php") || return
    FOLDER_KEYS[0]=$(echo "$XML" | parse_tag . 'folderkey') || return
    FOLDER_NAMES[0]=$(echo "$XML" | parse_tag . 'name') || return
    IDX=0

    while [ $IDX -lt ${#FOLDER_NAMES[@]} ]; do

        # Check whether we found the correct folder
        if [ "${FOLDER_NAMES[$IDX]}" = "$NAME" ]; then
            log_debug "Folder found! Folder key: '${FOLDER_KEYS[$IDX]}'"
            echo "${FOLDER_KEYS[$IDX]}"
            return 0
        fi

        # Get all sub folders
        XML=$(curl -d "session_token=$SESSION_KEY" -d "folder_key=${FOLDER_KEYS[$IDX]}" -d 'content_type=folders' \
            "$BASE_URL/api/folder/get_content.php" | break_html_lines) || return
        KEYS=$(echo "$XML" | parse_all_tag_quiet 'folderkey')
        NAMES=$(echo "$XML" | parse_all_tag_quiet 'name')

        # Append names/keys (if any) to respective array
        if [ -n "$KEYS" ]; then
            while read -r LINE; do
                FOLDER_NAMES[${#FOLDER_NAMES[@]}]=$LINE
            done <<< "$NAMES"

            while read -r LINE; do
                FOLDER_KEYS[${#FOLDER_KEYS[@]}]=$LINE
            done <<< "$KEYS"
        fi

        (( ++IDX ))
    done

    log_error 'Invalid folder, choose from:' ${FOLDER_NAMES[*]}
    return $ERR_BAD_COMMAND_LINE
}

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
            LINK_PASSWORD=$(prompt_for_password) || return
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
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.mediafire.com'
    local XML UKEY USER SESSION_KEY FOLDER_KEY MFUL_CONFIG UPLOAD_KEY QUICK_KEY
    local N SIZE MAX_SIZE

    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS
    mediafire_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    SESSION_KEY=$(mediafire_extract_session_key "$COOKIE_FILE" "$BASE_URL") || return

    log_debug "Get uploader configuration"
    XML=$(curl -b "$COOKIE_FILE" "$BASE_URL/basicapi/uploaderconfiguration.php?$$" | \
        break_html_lines) || return

    MAX_SIZE=$(echo "$XML" | parse_tag 'max_file_size') || return

    # Check file size
    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$FOLDER" ]; then
        FOLDER_KEY=$(mediafire_check_folder "$SESSION_KEY" "$BASE_URL" "$FOLDER") || return
    else
        FOLDER_KEY=$(echo "$XML" | parse_tag folderkey) || return
    fi

    UKEY=$(echo "$XML" | parse_tag ukey) || return
    USER=$(echo "$XML" | parse_tag user) || return
    MFUL_CONFIG=$(echo "$XML" | parse_tag MFULConfig) || return

    log_debug "Folder Key: $FOLDER_KEY"
    log_debug "UKey: $UKEY"
    log_debug "MFULConfig: $MFUL_CONFIG"

    # HTTP header "Expect: 100-continue" seems to confuse server
    # Note: -b "$COOKIE_FILE" is not required here
    XML=$(curl_with_log -0 \
        -F "Filename=$DESTFILE" \
        -F "Upload=Submit Query" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        --user-agent 'Shockwave Flash' \
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
        log_error "Unexpected remote error: ${ERR_CODE:-n/a}"
        return $ERR_FATAL
    fi

    log_debug "polling for status update (with key $UPLOAD_KEY)"

    for N in 4 3 3 2 2 2; do
        wait $N seconds || return

        XML=$(curl --get -d "key=$UPLOAD_KEY" -d "MFULConfig=$MFUL_CONFIG" \
            "$BASE_URL/basicapi/pollupload.php") || return

        # <description>Verifying File</description>
        if match '<description>No more requests for this key</description>' "$XML"; then
            QUICK_KEY=$(echo "$XML" | parse_tag_quiet quickkey)
            break
        fi
    done

    if [ -z "$QUICK_KEY" ]; then
        log_error 'Could not get download link. Site updated?'
        return $ERR_FATAL
    fi

    if [ -n "$DESCRIPTION" -o -n "$PRIVATE_FILE" ]; then
        XML=$(curl -d "session_token=$SESSION_KEY" \
            -d "quick_key=$QUICK_KEY" \
            ${DESCRIPTION:+-d "description=$DESCRIPTION"} \
            ${PRIVATE_FILE:+-d 'privacy=private'} \
            "$BASE_URL/api/file/update.php") || return

        [ $(echo "$XML" | parse_tag_quiet 'result') = 'Success' ] || \
            log_error 'Could not set description/hide file.'
    fi

    # Note: Making a file private removes its password...
    if [ -n "$LINK_PASSWORD" ]; then
        XML=$(curl -d "session_token=$SESSION_KEY" \
            -d "quick_key=$QUICK_KEY" \
            -d "password=$LINK_PASSWORD" \
            "$BASE_URL/api/file/update_password.php") || return

        [ $(echo "$XML" | parse_tag_quiet 'result') = 'Success' ] || \
            log_error 'Could not set password.'
    fi

    echo "$BASE_URL/?$QUICK_KEY"
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

    list_submit "$LINKS" "$NAMES" 'http://www.mediafire.com/?' || return
}
