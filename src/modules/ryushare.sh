#!/bin/bash
#
# ryushare.com module
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
#
# Note: This module is a clone of uptobox.

MODULE_RYUSHARE_REGEXP_URL="https\?://\(www\.\)\?ryushare\.com/"

MODULE_RYUSHARE_DOWNLOAD_OPTIONS="
LINK_PASSWORD,p:,link-password:,PASSWORD,Used in password-protected files"
MODULE_RYUSHARE_DOWNLOAD_RESUME=yes
MODULE_RYUSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_RYUSHARE_UPLOAD_OPTIONS="
LINK_PASSWORD,p:,link-password:,PASSWORD,Protect a link with a password
TOEMAIL,,email-to:,EMAIL,<To> field for notification email"
MODULE_RYUSHARE_UPLOAD_REMOTE_SUPPORT=no

# Output a ryushare file download URL
# $1: cookie file (unused here)
# $2: ryushare url
# stdout: real file download link
ryushare_download() {
    eval "$(process_options ryushare "$MODULE_RYUSHARE_DOWNLOAD_OPTIONS" "$@")"

    local URL=$2
    local PAGE WAIT_TIME FILE_URL ERR CODE
    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_RAND FORM_METHOD FORM_DD

    PAGE=$(curl -b 'lang=english' "$URL") || return

    # The file you were looking for could not be found, sorry for any inconvenience
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
    FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname')
    FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')

    PAGE=$(curl -b 'lang=english' -d 'referer=' \
        -d "op=$FORM_OP" \
        -d "usr_login=$FORM_USR" \
        -d "id=$FORM_ID" \
        -d "fname=$FORM_FNAME" \
        -d "method_free=$FORM_METHOD" "$URL") || return

    if match '<div class="err">' "$PAGE"; then
        # Sorry! User who was uploaded this file requires premium to download.
        if match 'file requires premium' "$PAGE"; then
            return $ERR_LINK_NEED_PERMISSIONS

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

    # Check for password protected link
    if match '"password"' "$PAGE"; then
        log_debug "File is password protected"
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD="$(prompt_for_password)" || return
        fi
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
    FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand')
    FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name 'method_free')
    FORM_DD=$(echo "$FORM_HTML" | parse_form_input_by_name 'down_direct')

    # Funny captcha, this is text (4 digits)!
    # Copy/Paste from uptobox
    if match 'Enter code below:' "$PAGE"; then
        local CAPTCHA DIGIT XCOORD LINE

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
    fi

    WAIT_TIME=$(echo "$PAGE" | parse_tag countdown_str span)
    wait $((WAIT_TIME + 1)) || return

    # Didn't included -d 'method_premium='
    PAGE=$(curl -b 'lang=english' -d "referer=$URL" \
        -d "op=$FORM_OP" \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d "method_free=$FORM_METHOD" \
        -d "down_direct=$FORM_DD" \
        -d "password=$LINK_PASSWORD" \
        -d "code=$CODE" \
        "$URL") || return

    FILE_URL=$(echo "$PAGE" | parse_attr_quiet 'here to download' href)
    if match_remote_url "$FILE_URL"; then
        # Workaround to avoid "Skipped countdown" error
        wait 2 || return

        echo "$FILE_URL"
        echo "$FORM_FNAME"
        return 0
    fi

    if match '<div class="err">' "$PAGE"; then
        ERR=$(echo "$PAGE" | parse_tag  'class="err">' div)
        if match 'Wrong password' "$ERR"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        elif match 'Wrong captcha' "$ERR"; then
            return $ERR_CAPTCHA
        fi
        log_error "Remote error: $ERR"
    else
        log_error "Unexpected content, site updated?"
    fi

    return $ERR_FATAL
}

# Upload a file to ryushare.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
ryushare_upload() {
    eval "$(process_options ryushare "$MODULE_RYUSHARE_UPLOAD_OPTIONS" "$@")"

    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://ryushare.com'

    local PAGE URL UPLOAD_ID USER_TYPE DL_URL DEL_URL

    PAGE=$(curl -b 'lang=english' "$BASE_URL") || return

    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_TMP_SRV
    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_UTYPE=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_type')
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id')
    FORM_TMP_SRV=$(echo "$FORM_HTML" | parse_form_input_by_name 'srv_tmp_url')

    UPLOAD_ID=$(random dec 12)
    USER_TYPE=anon

    # xupload.js
    # Note: HTTP header "Expect: 100-continue" seems to confuse server (lighttpd)
    #       Alternate solution: force HTTP/1.0 request (curl -0)
    PAGE=$(curl_with_log -b 'lang=english' --referer "$BASE_URL" -F 'tos=1' \
        -H 'Expect: ' \
        -F "upload_type=$FORM_UTYPE" \
        -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        -F "file_0_descr=" \
        -F "file_1=@/dev/null;filename=" \
        -F "link_rcpt=$TOEMAIL" \
        -F "link_pass=$LINK_PASSWORD" \
        "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=$FORM_UTYPE" | \
        break_html_lines) || return

    # Sanity check
    if match '>417 - Expectation Failed<' "$PAGE"; then
        log_error "upstream error (417)"
        return $ERR_FATAL
    fi

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
        echo "$LINK_PASSWORD"
        return 0
    fi

    log_error "Unexpected status: $FORM2_ST"
    return $ERR_FATAL
}
