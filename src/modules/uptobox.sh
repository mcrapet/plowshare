#!/bin/bash
#
# uptobox.com module
# Copyright (c) 2012 Plowshare team
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

MODULE_UPTOBOX_REGEXP_URL="http\?://\(www\.\)\?uptobox\.com/"

MODULE_UPTOBOX_DOWNLOAD_OPTIONS=""
MODULE_UPTOBOX_DOWNLOAD_RESUME=yes
MODULE_UPTOBOX_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_UPTOBOX_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_UPTOBOX_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login
# $1: credentials string
# $2: cookie file
# $3: base url
uptobox_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT NAME

    LOGIN_DATA='op=login&login=$USER&password=$PASSWORD&x=10&y=10&redirect='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA$BASE_URL" "$BASE_URL") || return

    # Set-Cookie: login xfss
    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -n "$NAME" ]; then
        log_debug "Successfully logged in as $NAME member"
        return 0
    fi

    return $ERR_LOGIN_FAILED
}

# Output a uptobox file download URL
# $1: cookie file (unused here)
# $2: uptobox url
# stdout: real file download link
uptobox_download() {
    local URL=$2
    local PAGE WAIT_TIME CAPTCHA CODE DIGIT XCOORD FILE_URL

    PAGE=$(curl -b 'lang=english' "$URL") || return

    # The file you were looking for could not be found, sorry for any inconvenience
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Send (post) form
    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_RAND FORM_METHOD FORM_DD
    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op')
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
    FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname')
    FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')

    PAGE=$(curl -b 'lang=english' -F 'referer=' \
        -F "op=$FORM_OP" \
        -F "usr_login=$FORM_USR" \
        -F "id=$FORM_ID" \
        -F "fname=$FORM_FNAME" \
        -F "method_free=$FORM_METHOD" "$URL") || return

    if match 'Enter code below:' "$PAGE"; then
        WAIT_TIME=$(echo "$PAGE" | parse_tag countdown_str span)

        FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
        FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op')
        FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
        FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand')
        FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name 'method_free')
        FORM_DD=$(echo "$FORM_HTML" | parse_form_input_by_name 'down_direct')

        # Funny captcha, this is text (4 digits)!
        # <span style='position:absolute;padding-left:64px;padding-top:3px;'>&#55;</span>
        CAPTCHA=$(echo "$FORM_HTML" | parse_tag 'direction:ltr' div | \
            sed -e 's/span>/span>\n/g') || return
        CODE=0
        while read LINE; do
            DIGIT=$(echo "$LINE" | parse 'padding-' '>&#\([[:digit:]]\+\);<') || return
            XCOORD=$(echo "$LINE" | parse 'padding-' '-left:\([[:digit:]]\+\)p') || return

            # Depending x, guess digit rank
            if (( XCOORD < 15 )); then
                (( CODE = CODE + 1000 * (DIGIT-48) ))
            elif (( XCOORD < 30 )); then
                (( CODE = CODE + 100 * (DIGIT-48) ))
            elif (( XCOORD < 50 )); then
                (( CODE = CODE + 10 * (DIGIT-48) ))
            else
                (( CODE = CODE + (DIGIT-48) ))
            fi
        done <<< "$CAPTCHA"

        wait $((WAIT_TIME)) || return

        # Didn't included -F 'method_premium='
        PAGE=$(curl -b 'lang=english' -F "referer=$URL" \
            -F "op=$FORM_OP" \
            -F "usr_login=$FORM_USR" \
            -F "id=$FORM_ID" \
            -F "rand=$FORM_RAND" \
            -F "method_free=$FORM_METHOD" \
            -F "down_direct=$FORM_DD" \
            -F "code=$CODE" "$URL") || return

        FILE_URL=$(echo "$PAGE" | parse_attr_quiet 'start your download' href)
        if match_remote_url "$FILE_URL"; then
            echo "$FILE_URL"
            echo "$FORM_FNAME"
            return 0
        fi

        # <p class="err">Wrong captcha</p>
        if match 'Wrong captcha' "$PAGE"; then
            return $ERR_CAPTCHA
        fi

    elif match '<p class="err">' "$PAGE"; then
        # You have reached the download-limit: 1024 Mb for last 1 days</p>
        if match 'reached the download.limit' "$PAGE"; then
            echo 3600
            return $ERR_LINK_TEMP_UNAVAILABLE
        # You have to wait X minutes, Y seconds till next download
        elif matchi 'You have to wait' "$PAGE"; then
            local MINS SECS
            MINS=$(echo "$PAGE" | \
                parse_quiet 'class="err">' 'wait \([[:digit:]]\+\) minute')
            SECS=$(echo "$PAGE" | \
                parse_quiet 'class="err">' ', \([[:digit:]]\+\) second')

            echo $(( MINS * 60 + SECS ))
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi
    fi

    log_error "Unexpected content, site updated?"
    return $ERR_FATAL
}

# Upload a file to uptobox.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
uptobox_upload() {
    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://uptobox.com'

    local PAGE URL UPLOAD_ID USER_TYPE DL_URL DEL_URL

    if [ -n "$AUTH" ]; then
        uptobox_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
        USER_TYPE=reg
    else
        USER_TYPE=anon
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' "$BASE_URL") || return

    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_TMP_SRV
    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_UTYPE=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_type')
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id')
    FORM_TMP_SRV=$(echo "$FORM_HTML" | parse_form_input_by_name 'srv_tmp_url')

    UPLOAD_ID=$(random dec 10)

    # xupload.js
    PAGE=$(curl_with_log \
        -F "upload_type=$FORM_UTYPE" \
        -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=$FORM_UTYPE" | \
         break_html_lines) || return

    local FORM2_ACTION FORM2_FN FORM2_ST FORM2_OP
    FORM2_ACTION=$(echo "$PAGE" | parse_form_action) || return
    FORM2_FN=$(echo "$PAGE" | parse_tag 'fn.>' textarea)
    FORM2_ST=$(echo "$PAGE" | parse_tag 'st.>' textarea)
    FORM2_OP=$(echo "$PAGE" | parse_tag 'op.>' textarea)

    if [ "$FORM2_ST" = 'OK' ]; then
        PAGE=$(curl -b 'lang=english' \
            -d "fn=$FORM2_FN" -d "st=$FORM2_ST" -d "op=$FORM2_OP" \
            "$FORM2_ACTION") || return

        DL_URL=$(echo "$PAGE" | parse 'Download Link' '">\([^<]*\)' 1) || return
        DEL_URL=$(echo "$PAGE" | parse_tag 'killcode' textarea)

        echo "$DL_URL"
        echo "$DEL_URL"
        return 0
    fi

    log_error "Unexpected status: $FORM2_ST"
    return $ERR_FATAL
}
