# Plowshare cramit.in module
# Copyright (c) 2012-2013 Plowshare team
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
# Note: This module is similar to uptobox and oron.

MODULE_CRAMIT_REGEXP_URL='https\?://\(www\.\)\?\(cramit\.in\|cramitin\.\(net\|us\|eu\)\)/'

MODULE_CRAMIT_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_CRAMIT_DOWNLOAD_RESUME=yes
MODULE_CRAMIT_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_CRAMIT_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_CRAMIT_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_CRAMIT_UPLOAD_REMOTE_SUPPORT=no

MODULE_CRAMIT_LIST_OPTIONS=""
MODULE_CRAMIT_LIST_HAS_SUBFOLDERS=yes

MODULE_CRAMIT_DELETE_OPTIONS=""
MODULE_CRAMIT_PROBE_OPTIONS=""

# Static function. Proceed with login (free or premium)
cramit_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT STATUS NAME

    LOGIN_DATA='op=login&redirect=&login=$USER&password=$PASSWORD&x=0&y=0'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.html" -L | break_html_lines) || return

    # If successful, two entries are added into cookie file: login and xfss
    STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
    if [ -z "$STATUS" ]; then
        return $ERR_LOGIN_FAILED
    fi

    NAME=$(parse_cookie 'login' < "$COOKIE_FILE")
    log_debug "Successfully logged in as $NAME member"

    # Export Hotlinks
    # Remaining Hotlink Bandwidth this month
    if match 'Hotlink' "$LOGIN_RESULT"; then
        echo 'premium'
    else
        echo 'free'
    fi
}

# Output a cramit file download URL
# $1: cookie file (account only)
# $2: cramit url
# stdout: real file download link
cramit_download() {
    local COOKIE_FILE=$1
    local URL=$2
    local BASE_URL='http://cramit.in'
    local PAGE TYPE FILE_URL CAPTCHA_URL WAIT_TIME HEADERS ERR

    TYPE=anon
    if [ -n "$AUTH" ]; then
        TYPE=$(cramit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    PAGE=$(curl -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL" | \
        break_html_lines_alt) || return

    # The file you were looking for could not be found, sorry for any inconvenience
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi


    if [ "$TYPE" != 'premium' ]; then
        # Send (post) form
        local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_RAND FORM_METHOD FORM_DD
        FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
        FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op')
        FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
        FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
        FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname')
        FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name 'free_method')

        PAGE=$(curl -b "$COOKIE_FILE" -F 'referer=' \
            -F "op=$FORM_OP" \
            -F "usr_login=$FORM_USR" \
            -F "id=$FORM_ID" \
            -F "fname=$FORM_FNAME" \
            -F "free_method=$FORM_METHOD" "$URL" | break_html_lines_alt) || return
    fi

    # Check for password protected link
    if match '"password"' "$PAGE"; then
        log_debug 'File is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi
    fi

    if match 'Enter the captcha below:' "$PAGE"; then
        FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
        FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op')
        FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
        FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand')
        FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name 'method_free')
        FORM_DD=$(echo "$FORM_HTML" | parse_form_input_by_name 'down_direct')

        # 4 digit captcha
        CAPTCHA_URL=$(echo "$PAGE" | parse_attr '/captchas/' 'src') || return

        local WI WORD ID
        WI=$(captcha_process "$CAPTCHA_URL") || return
        { read WORD; read ID; } <<<"$WI"

        # Didn't included -F 'method_premium='
        PAGE=$(curl -b "$COOKIE_FILE" -F "referer=$URL" \
            -F "op=$FORM_OP" \
            -F "id=$FORM_ID" \
            -F "rand=$FORM_RAND" \
            -F "method_free=$FORM_METHOD" \
            -F "down_direct=$FORM_DS" \
            -F "password=$LINK_PASSWORD" \
            -F "code=$WORD" "$URL" | break_html_lines_alt) || return

        if match 'File location :' "$PAGE"; then
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug 'correct captcha'

    elif match '<p class="err">' "$PAGE"; then
        # You have to wait X minutes before your next download
        if matchi 'You have to wait' "$PAGE"; then
            WAIT_TIME=$(echo "$PAGE" | parse 'u have to wait' \
                '^\([[:digit:]]\+\) \(minute\|second\)' 1) || return
            if match 'minute' "$PAGE"; then
                echo $(( WAIT_TIME * 60 + 30 ))
            else
                echo $WAIT_TIME
            fi
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

    # Premium download
    elif [ "$TYPE" = 'premium' ]; then
        FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
        FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op')
        FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
        FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand')
        FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name 'method_premium')
        FORM_DD=$(echo "$FORM_HTML" | parse_form_input_by_name 'down_direct')

        PAGE=$(curl -b "$COOKIE_FILE" -F "referer=$URL" \
            -F "op=$FORM_OP" \
            -F "id=$FORM_ID" \
            -F "rand=$FORM_RAND" \
            -F 'method_free=' -F "method_premium=$FORM_METHOD" \
            -F "down_direct=$FORM_DS" \
            -F "password=$LINK_PASSWORD" \
            "$URL" | break_html_lines_alt) || return

    else
        log_error 'Unexpected content, site updated?'
        return $ERR_FATAL
    fi

    # <p class="err">
    if match 'Wrong password' "$PAGE"; then
        return $ERR_LINK_PASSWORD_REQUIRED

    # Note: get sometimes "Skipped countdown" errors with premium. What's this?
    elif match '<p class="err">' "$PAGE"; then
        ERR=$(echo "$PAGE" | parse 'class="err">' '^\([^<]*\)' 1)
        log_error "Remote error: $ERR"
        return $ERR_FATAL
    fi

    echo "$PAGE" | parse_attr '/cgi-bin/' href || return
    echo "$FORM_FNAME"
}

# Upload a file to cramit
# $1: cookie file (account only)
# $2: file path or remote url
# $3: remote filename
# stdout: cramit download link and delete link
cramit_upload() {
    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://cramit.in'

    local PAGE URL UPLOAD_ID USER_TYPE DL_URL DEL_URL

    if [ -n "$AUTH" ]; then
        cramit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" >/dev/null || return
    fi

    PAGE=$(curl -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$BASE_URL" | \
        break_html_lines_alt) || return

    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_TMP_SRV
    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_UTYPE=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_type')
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id')
    FORM_TMP_SRV=$(echo "$FORM_HTML" | parse_form_input_by_name 'srv_tmp_url')

    UPLOAD_ID=$(random dec 12)
    USER_TYPE=anon

    # Note: -F "file_0_public=0" has no effect
    PAGE=$(curl_with_log \
        -F "upload_type=$FORM_UTYPE" \
        -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        --form-string "link_rcpt=$TOEMAIL" \
        --form-string "link_pass=$LINK_PASSWORD" \
        "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=$FORM_UTYPE" | \
         break_html_lines) || return

    local FORM2_ACTION FORM2_FN FORM2_ST FORM2_OP
    FORM2_ACTION=$(echo "$PAGE" | parse_form_action) || return
    FORM2_FN=$(echo "$PAGE" | parse_tag 'fn.>' textarea)
    FORM2_ST=$(echo "$PAGE" | parse_tag 'st.>' textarea)
    FORM2_OP=$(echo "$PAGE" | parse_tag 'op.>' textarea)

    if [ "$FORM2_ST" = 'OK' ]; then
        PAGE=$(curl -d "fn=$FORM2_FN" -d "st=$FORM2_ST" -d "op=$FORM2_OP" \
            "$FORM2_ACTION" | break_html_lines) || return

        DL_URL=$(echo "$PAGE" | parse '\.in Link' \
            'value="\([^"]*\)">' 2) || return
        DEL_URL=$(echo "$PAGE" | parse_attr 'killcode' value)

        echo "$DL_URL"
        echo "$DEL_URL"
        echo "$LINK_PASSWORD"
        return 0
    fi

    log_error "Unexpected status: $FORM2_ST"
    return $ERR_FATAL
}

# List a cramit folder
# $1: cramit user link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
cramit_list() {
    local URL=$1
    local RET=0

    if ! match '/user/' "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    cramit_list_rec "$2" "$URL" || RET=$?
    return $RET
}

# static recursive function
# $1: recursive flag
# $2: web folder URL
cramit_list_rec() {
    local REC=$1
    local URL=$2
    local PAGE PAGE2 LINKS NAMES RET LINE

    RET=$ERR_LINK_DEAD
    PAGE=$(curl -L "$URL" | break_html_lines) || return

    if match '"tbl_pub"' "$PAGE"; then
        PAGE2=$(echo "$PAGE" | parse_all '"tbl_pub"' '^\(.*\)$' 1)
        NAMES=$(echo "$PAGE2" | parse_all_tag a)
        LINKS=$(echo "$PAGE2" | parse_all_attr href)
        list_submit "$LINKS" "$NAMES" && RET=0
    fi

    if test "$REC" && match 'folder2\.gif' "$PAGE"; then
        LINKS=$(echo "$PAGE" | parse_all 'folder2\.gif' '^\(.*\)$' 1)

        # Drop ".." directory
        LINKS=$(echo "$LINKS" | delete_first_line)

        while read LINE; do
            test "$LINE" || continue
            URL=$(echo "$LINE" | parse_attr href)
            log_debug "entering sub folder: $URL"
            cramit_list_rec "$REC" "$URL" && RET=0
        done <<< "$LINKS"
    fi

    return $RET
}

# Delete a file from Cramit
# $1: cookie file
# $2: cramit (delete) link
cramit_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://cramit.in/'
    local PAGE FILE_ID DEL_ID

    FILE_ID=$(echo "$URL" | parse . 'cramit\.in/\(.\+\)?kill') || return
    DEL_ID=$(echo "$URL" | parse . '?killcode=\(.\+\)$') || return

    log_debug "FILE_ID: '$FILE_ID'"
    log_debug "Del_ID: '$DEL_ID'"

    PAGE=$(curl "$URL") || return

    if match 'Do you want to delete file' "$PAGE"; then
        PAGE=$(curl -d 'op=del_file' -d "id=$FILE_ID" -d "del_id=$DEL_ID" \
            -d 'confirm=yes' "$BASE_URL") || return

        match 'File deleted successfully' "$PAGE" && return 0

    elif match 'No such file exist' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: cramit url
# $3: requested capability list
# stdout: 1 capability per line
cramit_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L -b 'lang=english' "$URL" | break_html_lines_alt) || return

    # The file you were looking for could not be found, sorry for any inconvenience
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_form_input_by_name 'fname' <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse 'File location' '(\([^)]*\)' 5) && \
            translate_size "${FILE_SIZE/b/B}" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
