# Plowshare ryushare.com module
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
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare. If not, see <http://www.gnu.org/licenses/>.
#
# Note: This module is a clone of uptobox.

MODULE_RYUSHARE_REGEXP_URL='https\?://\(www\.\)\?ryushare\.com/'

MODULE_RYUSHARE_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_RYUSHARE_DOWNLOAD_RESUME=yes
MODULE_RYUSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_RYUSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_RYUSHARE_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_RYUSHARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_RYUSHARE_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: credentials string
# $2: cookie file
# $3: base url
ryushare_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT STATUS NAME

    LOGIN_DATA='op=login&login=$USER&password=$PASSWORD&loginFormSubmit=Login&redirect='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA$BASE_URL" \
        "$BASE_URL" -L) || return

    # If successful, two entries are added into cookie file: login and xfss
    STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
    if [ -z "$STATUS" ]; then
        return $ERR_LOGIN_FAILED
    fi

    NAME=$(parse_cookie 'login' < "$COOKIE_FILE")
    log_debug "Successfully logged in as $NAME member"

    if match '>Renew premium<' "$LOGIN_RESULT"; then
        echo 'premium'
    else
        echo 'free'
    fi
}

# Output a ryushare file download URL
# $1: cookie file (account only)
# $2: ryushare url
# stdout: real file download link
ryushare_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://ryushare.com'
    local PAGE TYPE FILE_URL ERR
    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_RAND FORM_METHOD FORM_DD FORM_CODE

    if [ -n "$AUTH" ]; then
        TYPE=$(ryushare_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return

    # The file you were looking for could not be found, sorry for any inconvenience
    # The file was removed by adminstrator
    if match 'File Not Found\|file was removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi


    if [ "$TYPE" != 'premium' ]; then
        FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
        FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
        FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
        FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
        FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname') || return
        FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')

        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
            -d "op=$FORM_OP" \
            -d "usr_login=$FORM_USR" \
            -d "id=$FORM_ID" \
            --data-urlencode "fname=$FORM_FNAME" \
            -d 'referer=' \
            -d "method_free=$FORM_METHOD" "$URL") || return
    fi

    if match '<div class="err">' "$PAGE"; then
        ERR=$(echo "$PAGE" | parse_tag 'class="err">' div)

        # Sorry! User who was uploaded this file requires premium to download.
        if match 'file requires premium' "$ERR"; then
            return $ERR_LINK_NEED_PERMISSIONS

        # You have to wait X minutes, Y seconds till next download
        elif matchi 'You have to wait' "$ERR"; then
            local MINS SECS
            MINS=$(echo "$PAGE" | \
                parse_quiet 'class="err">' 'wait \([[:digit:]]\+\) minute')
            SECS=$(echo "$PAGE" | \
                parse_quiet 'class="err">' ', \([[:digit:]]\+\) second')

            log_error 'Forced delay between downloads.'
            echo $(( MINS * 60 + SECS ))
            return $ERR_LINK_TEMP_UNAVAILABLE

        # You have reached the download-limit!
        elif matchi 'You have reached the download.limit' "$ERR"; then
            echo 3600
            return $ERR_LINK_TEMP_UNAVAILABLE

        # You can download files up to 1024 Mb only.
        elif match 'You can download files up to .* only' "$ERR"; then
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi

        log_error "Remote error: $ERR"
        return $ERR_FATAL
    fi

    # Check for password protected link
    if match '"password"' "$PAGE"; then
        log_debug 'File is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand') || return
    FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')
    FORM_DD=$(echo "$FORM_HTML" | parse_form_input_by_name 'down_direct') || return
    FORM_CODE=$(echo "$FORM_HTML" | parse_form_input_by_name 'capcode') || return

    if [ "$TYPE" = 'premium' ]; then
        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
            -H 'Expect: ' \
            -d "op=$FORM_OP" \
            -d "id=$FORM_ID" \
            -d "rand=$FORM_RAND" \
            -d "referer=$URL" \
            -d "method_free=$FORM_METHOD" \
            -d 'method_premium=1' \
            -d "down_direct=$FORM_DD" \
            -d "password=$LINK_PASSWORD" \
            "$URL") || return
    else
        local RESP CHALL ID WAIT_TIME
        local -r PUBKEY='iEXF7zf8za89u9WFCdGzF.noOv34.L8S'

        RESP=$(solvemedia_captcha_process $PUBKEY) || return
        { read CHALL; read ID; } <<< "$RESP"

        WAIT_TIME=$(echo "$PAGE" | parse_tag countdown_str span)
        # Wait some more to avoid "Skipped countdown" error
        wait $((WAIT_TIME + 3)) || return

        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
            -d "op=$FORM_OP"     -d "id=$FORM_ID" -d "rand=$FORM_RAND"      \
            -d "referer=$URL"    -d "method_free=$FORM_METHOD"              \
            -d 'method_premium=' --data-urlencode "adcopy_challenge=$CHALL" \
            -d 'adcopy_response=manual_challenge' -d "capcode=$FORM_CODE"   \
            -d "down_direct=$FORM_DD" "$URL") || return
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr_quiet 'here to download' href)
    if match_remote_url "$FILE_URL"; then
        # Workaround to avoid "Skipped countdown" error
        wait 2 || return

        echo "$FILE_URL"
        echo "$FORM_FNAME"
        return 0
    fi

    if match '<div class="err">' "$PAGE"; then
        ERR=$(echo "$PAGE" | parse_tag 'class="err">' div)
        if match 'Wrong password' "$ERR"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        elif matchi 'Wrong captcha' "$ERR"; then
            return $ERR_CAPTCHA
        elif match 'Skipped countdown' "$ERR"; then
            # Can do a retry
            log_debug "Remote error: $ERR"
            return $ERR_NETWORK
        fi
        log_error "Remote error: $ERR"
    else
        log_error 'Unexpected content, site updated?'
    fi

    return $ERR_FATAL
}

# Upload a file to ryushare.com
# $1: cookie file (account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
ryushare_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://ryushare.com'

    local PAGE URL UPLOAD_ID USER_TYPE DL_URL DEL_URL

    if [ -n "$AUTH" ]; then
        ryushare_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" >/dev/null || return
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

    UPLOAD_ID=$(random dec 12)

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
        --form-string "link_rcpt=$TOEMAIL" \
        --form-string "link_pass=$LINK_PASSWORD" \
        "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=$FORM_UTYPE" | \
        break_html_lines) || return

    # Sanity check
    if match '>417 - Expectation Failed<' "$PAGE"; then
        log_error 'upstream error (417)'
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

# Probe a download URL
# $1: cookie file (unused here)
# $2: Ryushare url
# $3: requested capability list
# stdout: 1 capability per line
ryushare_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -b 'lang=english' "$URL") || return

    match 'File Not Found\|file was removed' "$PAGE" && return $ERR_LINK_DEAD
    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$PAGE" | parse_form_input_by_name 'fname' && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse 'You have requested' \
            '(\([[:digit:]]\+\(\.[[:digit:]]\+\)\?[[:space:]][KMG]\?B\)') && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
