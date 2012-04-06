#!/bin/bash
#
# oron.com module
# Copyright (c) 2012 Krompo@speed.1s.fr
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

MODULE_ORON_REGEXP_URL="http://\(www\.\)\?\(oron\)\.com/[[:alnum:]]\{12\}"

MODULE_ORON_DOWNLOAD_OPTIONS=""
MODULE_ORON_DOWNLOAD_RESUME=no
MODULE_ORON_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_ORON_UPLOAD_OPTIONS=""
MODULE_ORON_UPLOAD_REMOTE_SUPPORT=no

MODULE_ORON_DELETE_OPTIONS=""

# helper functions

# switch language to english
# $1: cookie file
# stdout: nothing
oron_switch_lang() {
    curl -b "$1" -c "$1" -o /dev/null \
        "http://oron.com/?op=change_lang&lang=english" || return
}

# generate a random number
# $1: digits
# stout: random number with $1 digits
oron_random_num() {
    local CC NUM DIGIT
    CC=0
    NUM=0

    while [ "$CC" -lt $1 ]; do
        DIGIT=$(($RANDOM % 10))
        NUM=$(($NUM * 10 + $DIGIT))
        CC=$((CC + 1))
    done

    echo $NUM
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
    local HTML SLEEP FILE_ID FILE_NAME REF METHOD HOURS MINS SECS RND

    # extract ID
    FILE_ID=$(echo "$URL" | parse "." \
        "oron\.com\/\([[:alnum:]]\{12\}\)\/\?") || return
    log_debug "file id=$FILE_ID"

    oron_switch_lang "$COOKIE_FILE"
    HTML=$(curl -b "$COOKIE_FILE" "$URL") || return

    # check the file for availability
    match "File Not Found" "$HTML" && return $ERR_LINK_DEAD
    test "$CHECK_LINK" && return 0

    # check, if file is special
    match "Free Users can only download files sized up to" "$HTML" && \
        return $ERR_LINK_NEED_PERMISSIONS

    # extract properties
    FILE_NAME=$(echo "$HTML" | parse_form_input_by_name "fname") || return
    REF=$(echo "$HTML" | parse_form_input_by_name "referer") || return
    METHOD=$(echo "$HTML" | parse_form_input_by_name "method_free" | \
        replace ' ' '+') || return
    log_debug "file name=$FILE_NAME"
    log_debug "method=$METHOD"
    log_debug "referer=$REF"

    # send download form
    HTML=$(curl -b "$COOKIE_FILE" \
        -F "op=download1" \
        -F "usr_login=" \
        -F "id=$FILE_ID" \
        -F "fname=$FILE_NAME" \
        -F "referer=$REF" \
        -F "method_free=$METHOD" \
        "$URL") || return

    # check for availability (yet again)
    match "File could not be found" "$HTML" && return $ERR_LINK_DEAD

    # retrieve waiting time
    HOURS=$(echo "$HTML" | parse_quiet '<p class="err">You have to wait' \
        ' \([[:digit:]]\+\) hours\?')
    MINS=$(echo "$HTML" | parse_quiet '<p class="err">You have to wait' \
        ' \([[:digit:]]\+\) minutes\?')
    SECS=$(echo "$HTML" | parse_quiet '<p class="err">You have to wait' \
        ' \([[:digit:]]\+\) seconds\?')

    if [ -n "$HOURS" -o -n "$MINS" -o -n "$SECS" ]; then
        [ -z "$HOURS" ] && HOURS=0
        [ -z "$MINS" ] && MINS=0
        [ -z "$SECS" ] && SECS=0
        echo $(($HOURS * 3600 + $MINS * 60 + $SECS))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # retrieve random value
    RND=$(echo "$HTML" | parse_form_input_by_name "rand") || return
    log_debug "random value: $RND"

    # retrieve sleep time
    # Please wait <span id="countdown">60</span> seconds
    SLEEP=$(echo "$HTML" | parse_tag 'Please wait' 'span') || return
    wait $((SLEEP + 1)) seconds || return

    # solve ReCaptcha
    local PUBKEY WCI CHALLENGE WORD ID DATA
    PUBKEY="6LdzWwYAAAAAAAzlssDhsnar3eAdtMBuV21rqH2N"
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    # send captcha form
    HTML=$(curl -b "$COOKIE_FILE" \
        -F "op=download2" \
        -F "id=$FILE_ID" \
        -F "rand=$RND" \
        -F "referer=$URL" \
        -F "method_free=$METHOD" \
        -F "method_premium=" \
        -F "recaptcha_challenge_field=$CHALLENGE" \
        -F "recaptcha_response_field=$WORD" \
        -F "down_direct=1" \
        "$URL") || return

    # check for possible errors
    if match "Wrong captcha" "$HTML"; then
        log_debug "incorrect captcha"
        recaptcha_nack $ID
        return $ERR_CAPTCHA
    elif match '<p class="err">Expired session</p>' "$HTML"; then
        echo 10 # just some arbitrary small value
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match "Download File</a></td>" "$HTML"; then
        log_debug "DL link found"
        FILE_URL=$(echo "$HTML" | parse_attr "Download File" "href") || return
    else
        log_error "No download link found. Site updated?"
        return $ERR_FATAL
    fi

    recaptcha_ack $ID

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

    local MAX_SIZE_FREE=$((400*1024*1024)) # anon uploads up to 400MB
    #local MAX_SIZE_REG=$((1024*1024*1024)) # reg uploads up to 1GB
    #local MAX_SIZE_PREM=$((2048*1024*1024)) # premium uploads up to 2GB

    local HTML FORM SRV_ID SESS_ID SRV_URL RND RND2 FN ST SIZE REMOTE_SIZE

    SIZE=$(get_filesize $FILE)
    if [ $SIZE -gt $MAX_SIZE_FREE ]; then
        log_error "File is too big - only $MAX_SIZE_FREE bytes are allowed."
        return ERR_FATAL
    fi

    oron_switch_lang "$COOKIE_FILE"
    HTML=$(curl -b "$COOKIE_FILE" 'http://oron.com/') || return

    # gather relevant data from form
    FORM=$(grep_form_by_name "$HTML" "file") || return
    SRV_ID=$(echo "$FORM" | parse_form_input_by_name "srv_id") || return
    SESS_ID=$(echo "$FORM" | parse_form_input_by_name "sess_id") || return
    SRV_URL=$(echo "$FORM" | parse_form_input_by_name "srv_tmp_url") || return
    RND=$(oron_random_num 12)

    log_debug "srvID: $SRV_ID"
    log_debug "sessID: $SESS_ID"
    log_debug "srvUrl: $SRV_URL"

    # prepare upload
    HTML=$(curl -b "$COOKIE_FILE" \
        "$SRV_URL/status.html?file=$RND=$DEST_FILE") || return

    if ! match "You are oroning" "$HTML"; then
        log_error "Error uploading to server $SRV_URL"
        return $ERR_FATAL
    fi

    # upload file
    HTML=$(curl_with_log -b "$COOKIE_FILE" \
        -F "upload_type=file" \
        -F "srv_id=$SRV_ID" \
        -F "sess_id=$SESS_ID" \
        -F "srv_tmp_url=$SRV_URL" \
        -F "file_0=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        -F "file_1=;filename=" \
        -F "ut=file" \
        -F "link_rcpt=" \
        -F "link_pass=" \
        -F "tos=1" \
        -F "submit_btn= Upload! " \
        "$SRV_URL/upload/$SRV_ID/?X-Progress-ID=$RND") || return

    # gather relevant data from form
    FORM=$(grep_form_by_name "$HTML" "F1" | break_html_lines_alt)
    FN=$(echo "$FORM" | parse_form_input_by_name "fn") || return
    ST=$(echo "$FORM" | parse_form_input_by_name "st") || return
    log_debug "FN: $FN"
    log_debug "ST: $ST"

    if [ "$ST" = "OK" ]; then
        log_debug "Upload was successfull."
    elif match "banned by administrator" "$ST"; then
        log_error "File is banned."
        return $ERR_FATAL
    else
        log_error "Unknown upload state: $ST"
        return $ERR_FATAL
    fi

    # ask for progress
    # (not sure if this is neccessary, but the browser does it at least once)
    RND2=$(oron_random_num 17)
    HTML=$(curl -b "$COOKIE_FILE" \
        --referer "$SRV_URL/status.html?file=$RND=$DEST_FILE" \
        --header "X-Progress-ID: $RND" \
        "$SRV_URL/progress?0.$RND2") || return

    # check upload state (yet again)
    # new Object({ 'state' : 'done' })
    if ! match "'state'[[:space:]]*:[[:space:]]*'done'" "$HTML"; then
        log_error "Invalid state"
        return $ERR_FATAL
    fi

    # get download url
    HTML=$(curl -b "$COOKIE_FILE" \
        -L 'http://oron.com' \
        -F "op=upload_result" \
        -F "fn=$FN" \
        -F "st=$ST") || return

    local LINK DEL_LINK
    LINK=$(echo "$HTML" | parse_line_after "Direct Link:" \
        'value=\"\([^\"]*\)\">') || return
    DEL_LINK=$(echo "$HTML" | parse_line_after "Delete Link:" \
        'value=\"\([^\"]*\)\">') || return

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
    local BASE_URL='http:\/\/oron\.com'

    # check + parse URL
    FILE_ID=$(echo "$URL" | parse "$BASE_URL" \
        "^${BASE_URL}\/\([[:alnum:]]\{12\}\)?killcode=[[:alnum:]]\{10\}$") || return
    log_debug "file ID: $FILE_ID"

    KILLCODE=$(echo "$URL" | parse "$BASE_URL" \
        "^${BASE_URL}\/[[:alnum:]]\{12\}?killcode=\([[:alnum:]]\{10\}\)") || return
    log_debug "killcode: $KILLCODE"

    oron_switch_lang "$COOKIEFILE"
    HTML=$(curl -b "$COOKIEFILE" -L "$URL") || return

    match "No such file exist" "$HTML" && return $ERR_LINK_DEAD

    HTML=$(curl -b "$COOKIEFILE" \
        -F "op=del_file" \
        -F "id=$FILE_ID" \
        -F "del_id=$KILLCODE" \
        -F "confirm=yes" \
        'http://oron.com') || return

    match "File deleted successfully" "$HTML" || return $ERR_FATAL
}
