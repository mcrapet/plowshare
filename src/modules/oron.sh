#!/bin/bash
#
# oron.com module
# Copyright (c) 2012 krompospeed@googlemail.com
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

MODULE_ORON_REGEXP_URL="http://\(www\.\)\?\(oron\)\.com/"

MODULE_ORON_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account
LINK_PASSWORD,p:,link-password:,PASSWORD,Used in password-protected files"
MODULE_ORON_DOWNLOAD_RESUME=no
MODULE_ORON_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_ORON_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account
LINK_PASSWORD,p:,link-password:,PASSWORD,Protect a link with a password
TOEMAIL,,email-to:,EMAIL,<To> field for notification email
PRIVATE_FILE,,private,,Do not make file visible in folder view (account only)"
MODULE_ORON_UPLOAD_REMOTE_SUPPORT=yes

MODULE_ORON_DELETE_OPTIONS=""

MODULE_ORON_LIST_OPTIONS=""

# Switch language to english
# $1: cookie file
# stdout: nothing
oron_switch_lang() {
    curl -b "$1" -c "$1" -o /dev/null \
        'http://oron.com/?op=change_lang&lang=english' || return
}

# Static function. Proceed with login (free or premium)
# $1: authentication
# $2: cookie file
# stdout: account type ("free" or "premium") on success
oron_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local LOGIN_DATA HTML NAME TYPE

    LOGIN_DATA='login=$USER&password=$PASSWORD&op=login&redirect=&rand='
    HTML=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
       'http://oron.com/login' -L -b "$COOKIE_FILE") || return

    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    [ -n "$NAME" ] || return $ERR_LOGIN_FAILED

    if match 'Become a PREMIUM Member' "$HTML"; then
        TYPE='free'
    elif match 'Extend Premium Account' "$HTML"; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    log_debug "Successfully logged in as $TYPE member '$NAME'"
    echo "$TYPE"
}

# Determine whether checkbox/radio button with "name" attribute is checked.
# Note: "checked" attribute must be placed after "name" attribute.
#
# $1: name attribute of checkbox/radio button
# $2: (X)HTML data
# $? is zero on success
oron_is_checked() {
    matchi "<input.*name=[\"']\?$1[\"']\?.*[[:space:]]checked" "$2"
}

# Extract file id from download link
# $1: oron.com url
# stdout: file id
oron_extract_file_id() {
    local FILE_ID
    FILE_ID=$(echo "$1" | parse '.' 'oron\.com/\([[:alnum:]]\{12\}\)') || return
    log_debug "File ID=$FILE_ID"
    echo "$FILE_ID"
}

# Output an oron.com file download URL
# $1: cookie file
# $2: oron.com url
# stdout: real file download link
#         file name
oron_download() {
    eval "$(process_options oron "$MODULE_ORON_DOWNLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local URL=$2
    local HTML FILE_ID FILE_URL FILE_NAME METHOD_F METHOD_P
    local RND OPT_PASSWD ACCOUNT

    oron_switch_lang "$COOKIE_FILE" || return

    # Login first so we get the direct download page for premium account
    if [ -n "$AUTH" ]; then
        ACCOUNT=$(oron_login "$AUTH" "$COOKIE_FILE") || return
    fi
    HTML=$(curl -b "$COOKIE_FILE" "$URL") || return

    # Check the file for availability
    match '<h2>File Not Found</h2>' "$HTML" && return $ERR_LINK_DEAD
    test "$CHECK_LINK" && return 0

    FILE_ID=$(oron_extract_file_id "$URL") || return
    FILE_NAME=$(echo "$HTML" | parse_form_input_by_name 'fname') || return

    # Request free download (anonymous, free)
    # Note: usr_login is empty even if logged in
    if [ "$ACCOUNT" != 'premium' ]; then
        # Send download request form
        HTML=$(curl -b "$COOKIE_FILE" \
            -F 'op=download1' \
            -F 'usr_login=' \
            -F "id=$FILE_ID" \
            -F "fname=$FILE_NAME" \
            -F 'referer=' \
            -F 'method_free= Regular Download ' \
            "$URL") || return

        # Check for availability (yet again)
        match 'File could not be found' "$HTML" && return $ERR_LINK_DEAD

        # Check if file is too large
        match 'Free Users can only download files sized up to' "$HTML" && \
            return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Check for file password protection (anonymous, free, premium)
    if match 'Password:[[:space:]]*<input' "$HTML"; then
        log_debug 'File is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD="$(prompt_for_password)" || return
        fi
        OPT_PASSWD="-F password=$LINK_PASSWORD"
    fi

    if [ "$ACCOUNT" != 'premium' ]; then
        # Prepare free download (anonymous, free)
        local SLEEP DAYS HOURS MINS SECS PUBKEY WCI CHALLENGE WORD ID

        # Retrieve wait time
        # You have to wait xx hours, xx minutes, xx seconds until the next download becomes available.
        DAYS=$(echo "$HTML" | parse_quiet '<p class="err">You have to wait' \
            ' \([[:digit:]]\+\) days\?')
        HOURS=$(echo "$HTML" | parse_quiet '<p class="err">You have to wait' \
            ' \([[:digit:]]\+\) hours\?')
        MINS=$(echo "$HTML" | parse_quiet '<p class="err">You have to wait' \
            ' \([[:digit:]]\+\) minutes\?')
        SECS=$(echo "$HTML" | parse_quiet '<p class="err">You have to wait' \
            ' \([[:digit:]]\+\) seconds\?')

        if [ -n "$DAYS" -o -n "$HOURS" -o -n "$MINS" -o -n "$SECS" ]; then
            [ -z "$DAYS" ]  && DAYS=0
            [ -z "$HOURS" ] && HOURS=0
            [ -z "$MINS" ]  && MINS=0
            [ -z "$SECS" ]  && SECS=0
            echo $(( ((($DAYS * 24) + $HOURS) * 60 + $MINS) * 60 + $SECS ))
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        # Retrieve sleep time
        # Please wait <span id="countdown">60</span> seconds
        SLEEP=$(echo "$HTML" | parse_tag 'Please wait' 'span') || return
        wait $((SLEEP + 1)) seconds || return

        # Solve ReCaptcha
        PUBKEY='6LdzWwYAAAAAAAzlssDhsnar3eAdtMBuV21rqH2N'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        CHALLENGE="-F recaptcha_challenge_field=$CHALLENGE"
        WORD="-F recaptcha_response_field=$WORD"
        METHOD_F=' Regular Download '
        METHOD_P=''
    else
        # Premium
        METHOD_F=''
        METHOD_P='1'
        MODULE_ORON_DOWNLOAD_RESUME=yes
    fi

    # Retrieve nonce (anonymous, free, premium)
    RND=$(echo "$HTML" | parse_form_input_by_name 'rand') || return
    log_debug "Random value: $RND"

    # Request download (no double quote around $OPT_PASSWD, $CHALLENGE, $WORD)
    HTML=$(curl -b "$COOKIE_FILE" \
        -F 'op=download2' \
        -F "id=$FILE_ID" \
        -F "rand=$RND" \
        -F "referer=$URL" \
        -F "method_free=$METHOD_F" \
        -F "method_premium=$METHOD_P" \
        $OPT_PASSWD \
        $CHALLENGE \
        $WORD \
        -F 'down_direct=1' \
        "$URL") || return

    # Check for possible errors
    if match 'Wrong captcha' "$HTML"; then
        log_error 'Wrong captcha'
        captcha_nack $ID
        return $ERR_CAPTCHA
    elif match '<p class="err">Expired session</p>' "$HTML"; then
        log_error 'Session expired'
        echo 10 # just some arbitrary small value
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'Download File</a></td>' "$HTML"; then
        log_debug 'DL link found'
        FILE_URL=$(echo "$HTML" | parse_attr 'Download File' 'href') || return
    elif match 'Retype Password' "$HTML"; then
        log_error 'Incorrect link password'
        return $ERR_LINK_PASSWORD_REQUIRED
    else
        log_error 'No download link found. Site updated?'
        return $ERR_FATAL
    fi

    [ "$ACCOUNT" != 'premium' ] && captcha_ack $ID

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to oron.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
#         delete link
oron_upload() {
    eval "$(process_options oron "$MODULE_ORON_UPLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local FILE=$2
    local DEST_FILE=$3
    local BASE_URL='http://oron.com'
    local SIZE HTML FORM SRV_ID SESS_ID SRV_URL RND FN ST
    local OPT_EMAIL MAX_SIZE ACCOUNT

    oron_switch_lang "$COOKIE_FILE" || return

    # Login and set max file size (depends on account type)
    if [ -n "$AUTH" ]; then
        ACCOUNT=$(oron_login "$AUTH" "$COOKIE_FILE") || return

        if [ "$ACCOUNT" = 'free' ]; then
            MAX_SIZE=$((1024*1024*1024)) # free up to 1GB
        else
            MAX_SIZE=$((2048*1024*1024)) # premium up to 2GB
        fi
    else
        MAX_SIZE=$((400*1024*1024)) # anonymous up to 400MB

        [ -z "$PRIVATE_FILE" ] || \
            log_error 'option "--private" ignored, account only'
        [ -z "$LINK_PASSWORD" ] || \
            log_error "Specified password is ignored for anonymous uploads"
    fi

    if match_remote_url "$FILE"; then
        if [ -z "$ACCOUNT" ]; then
            log_error 'Remote upload requires an account (free or premium)'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    else
        # File size seem to matter only for file upload
        SIZE=$(get_filesize "$FILE")
        if [ $SIZE -gt $MAX_SIZE ]; then
            log_debug "file is bigger than $MAX_SIZE"
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    HTML=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return

    # Gather relevant data from form
    FORM=$(grep_form_by_name "$HTML" 'file') || return
    SRV_ID=$(echo "$FORM" | parse_form_input_by_name_quiet 'srv_id') || return
    SESS_ID=$(echo "$FORM" | parse_form_input_by_name_quiet 'sess_id') || return
    SRV_URL=$(echo "$FORM" | parse_form_input_by_name_quiet 'srv_tmp_url') || return
    RND=$(random d 12)

    log_debug "Server ID: $SRV_ID"
    log_debug "Session ID: $SESS_ID"
    log_debug "Server URL: $SRV_URL"

    # Prepare upload
    if match_remote_url "$FILE"; then
        HTML=$(curl -b "$COOKIE_FILE" \
            "$SRV_URL/status.html?url=$RND=$DEST_FILE") || return
    else
        HTML=$(curl -b "$COOKIE_FILE" \
            "$SRV_URL/status.html?file=$RND=$DEST_FILE") || return
    fi

    if ! match 'You are oroning' "$HTML"; then
        log_error "Error uploading to server '$SRV_URL'."
        return $ERR_FATAL
    fi

    # Upload file
    if match_remote_url "$FILE"; then
        HTML=$(curl -b "$COOKIE_FILE" \
            -F "srv_id=$SRV_ID" \
            -F "sess_id=$SESS_ID" \
            -F 'upload_type=url' \
            -F 'utype=reg' \
            -F "srv_tmp_url=$SRV_URL" \
            -F 'mass_upload=1' \
            -F "url_mass=$FILE" \
            -F "link_rcpt=$EMAIL" \
            -F "link_pass=$LINK_PASSWORD" \
            -F 'tos=1' \
            -F 'submit_btn= Upload! ' \
            "$SRV_URL/cgi-bin/upload_url.cgi/?X-Progress-ID=$RND") || return

        # Gather relevant data
        FORM=$(grep_form_by_name "$HTML" 'F1' | break_html_lines) || return
        FN=$(echo "$FORM" | parse_tag 'fn' 'textarea') || return
        ST=$(echo "$FORM" | parse_tag 'st' 'textarea') || return

    else
        HTML=$(curl_with_log -b "$COOKIE_FILE" \
            -F 'upload_type=file' \
            -F "srv_id=$SRV_ID" \
            -F "sess_id=$SESS_ID" \
            -F "srv_tmp_url=$SRV_URL" \
            -F "file_0=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
            -F 'file_1=;filename=' \
            -F 'ut=file' \
            -F "link_rcpt=$EMAIL" \
            -F "link_pass=$LINK_PASSWORD" \
            -F 'tos=1' \
            -F 'submit_btn= Upload! ' \
            "$SRV_URL/upload/$SRV_ID/?X-Progress-ID=$RND") || return

        # Gather relevant data
        FORM=$(grep_form_by_name "$HTML" 'F1' | break_html_lines_alt) || return
        FN=$(echo "$FORM" | parse_form_input_by_name_quiet 'fn') || return
        ST=$(echo "$FORM" | parse_form_input_by_name_quiet 'st') || return
    fi

    log_debug "FN: $FN"
    log_debug "ST: $ST"

    if [ "$ST" = 'OK' ]; then
        log_debug 'Upload was successfull.'
    elif match 'banned by administrator' "$ST"; then
        log_error 'File is banned by admin.'
        return $ERR_FATAL
    elif match 'triggered our security filters' "$ST"; then
        log_error 'File is banned by security filter.'
        return $ERR_FATAL
    elif match 'Received HTML page instead of file' "$ST"; then
        log_error 'HTML page was received instead of a file. Does your link redirect?'
        return $ERR_FATAL
    else
        log_error "Unknown upload state: $ST"
        return $ERR_FATAL
    fi

    [ -n "$TOEMAIL" ] && OPT_EMAIL="-F link_rcpt=$TOEMAIL"

    # Get download url (no double quote around $OPT_EMAIL)
    HTML=$(curl -b "$COOKIE_FILE" \
        -F 'op=upload_result' \
        $OPT_EMAIL \
        -F "fn=$FN" \
        -F "st=$ST" \
        "$BASE_URL") || return

    local LINK DEL_LINK
    LINK=$(echo "$HTML" | parse 'Direct Link:' 'value="\([^"]*\)">' 1) || return
    DEL_LINK=$(echo "$HTML" | parse 'Delete Link:' 'value="\([^"]*\)">' 1) || return

    # Do we need to edit the file? (change name/visibility)
    if [ -n "$ACCOUNT" -a -z "$PRIVATE_FILE" ] || \
        ( match_remote_url "$FILE" && [ "$DEST_FILE" != 'dummy' ] ); then
        log_debug 'Editing file...'

        local FILE_ID F_NAME F_PASS F_PUB
        FILE_ID=$(oron_extract_file_id "$LINK") || return

        # Retrieve current values
        HTML=$(curl -b "$COOKIE_FILE" \
            "$BASE_URL/?op=file_edit;file_code=$FILE_ID") || return

        F_NAME=$(echo "$HTML" | parse_form_input_by_name_quiet 'file_name') || return
        F_PASS=$(echo "$HTML" | parse_form_input_by_name_quiet 'file_password') || return
        oron_is_checked 'file_public' "$HTML" && F_PUB='1'

        log_debug "Current name: $F_NAME"
        log_debug "Current pass: ${F_PASS//?/*}"
        [ -n "$F_PUB" ] && log_debug 'Currently public'

        match_remote_url "$FILE" && [ "$DEST_FILE" != 'dummy' ] && F_NAME=$DEST_FILE
        [ -n "$ACCOUNT" -a -z "$PRIVATE_FILE" ] && F_PUB='1'
        [ -n "$LINK_PASSWORD" ] && F_PASS="$LINK_PASSWORD"

        # Post changes (include HTTP headers to check for proper redirection)
        HTML=$(curl -i -b "$COOKIE_FILE" \
            -F "file_name=$F_NAME" \
            -F "file_password=$F_PASS" \
            -F "file_public=$F_PUB" \
            -F 'op=file_edit' \
            -F "file_code=$FILE_ID" \
            -F 'save= Submit ' \
            "$BASE_URL/?op=file_edit;file_code=$FILE_ID") || return

        HTML=$(echo "$HTML" | grep_http_header_location) || return
        match '?op=my_files' "$HTML" || log_error 'Could not edit file. Site update?'
    fi

    echo "$LINK"
    echo "$DEL_LINK"
}

# Delete a file on oron.com
# $1: cookie file
# $2: kill URL
oron_delete() {
    eval "$(process_options oron "$MODULE_ORON_DELETE_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL=$2
    local HTML FILE_ID KILLCODE

    # Check + parse URL
    FILE_ID=$(oron_extract_file_id "$URL") || return
    KILLCODE=$(echo "$URL" | parse . \
        "^http://oron\.com/[[:alnum:]]\{12\}?killcode=\([[:alnum:]]\{10\}\)") || return
    log_debug "Killcode: $KILLCODE"

    oron_switch_lang "$COOKIEFILE" || return
    HTML=$(curl -b "$COOKIEFILE" -L "$URL") || return

    match 'No such file exist' "$HTML" && return $ERR_LINK_DEAD

    HTML=$(curl -b "$COOKIEFILE" \
        -F 'op=del_file' \
        -F "id=$FILE_ID" \
        -F "del_id=$KILLCODE" \
        -F 'confirm=yes' \
        'http://oron.com') || return

    match 'File deleted successfully' "$HTML" || return $ERR_FATAL
}

# List an oron web folder URL
# $1: oron URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
oron_list() {
    eval "$(process_options oron "$MODULE_ORON_LIST_OPTIONS" "$@")"

    local URL=$1
    local RET=0

    if ! match 'oron\.com/folder/' "$1"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    oron_list_rec "$2" "$URL" || RET=$?
    return $RET
}

# static recursive function
# $1: recursive flag
# $2: web folder URL
oron_list_rec() {
    local REC=$1
    local URL=$2
    local PAGE LINKS NAMES LINE

    RET=$ERR_LINK_DEAD
    PAGE=$(curl "$URL") || return

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet '<td id=' href)

    if [ -n "$LINKS" ]; then
        NAMES=$(echo "$PAGE" | parse_all_tag '<td id=' small)
        list_submit "$LINKS" "$NAMES" && RET=0
    fi

    # Are there any subfolders?
    if test "$REC" && match 'folder2\.gif' "$PAGE"; then
        LINKS=$(echo "$PAGE" | parse_all 'folder2\.gif' 'href="\([^"]*\)' 1)

        while read LINE; do
            log_debug "entering sub folder: $LINE"
            oron_list_rec "$REC" "$LINE" && RET=0
        done <<< "$LINKS"
    fi

    return $RET
}
