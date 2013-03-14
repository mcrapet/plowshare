#!/bin/bash
#
# 180upload.com module
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
# Note: This module is similar to filebox and zalaa (for upload)

MODULE_180UPLOAD_REGEXP_URL="https\?://\(www\.\)\?180upload\.com/"

MODULE_180UPLOAD_DOWNLOAD_OPTIONS=""
MODULE_180UPLOAD_DOWNLOAD_RESUME=yes
MODULE_180UPLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_180UPLOAD_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_180UPLOAD_UPLOAD_OPTIONS="
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_180UPLOAD_UPLOAD_REMOTE_SUPPORT=no

MODULE_180UPLOAD_PROBE_OPTIONS=""

# Output a 180upload.com file download URL
# $1: cookie file (account only)
# $2: 180upload.com url
# stdout: real file download link
180upload_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local PAGE FILE_NAME FILE_URL ERR
    local FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_DD FORM_METHOD_F FORM_METHOD_P

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return

    # File Not Found, Copyright infringement issue, file expired or deleted by its owner.
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand') || return
    FORM_DD=$(echo "$FORM_HTML" | parse_form_input_by_name 'down_direct') || return

    # Note: this is quiet parsing
    FORM_METHOD_F=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')
    FORM_METHOD_P=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_premium')

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -F 'referer=' \
        -F "op=$FORM_OP" \
        -F "id=$FORM_ID" \
        -F "rand=$FORM_RAND" \
        -F "down_direct=$FORM_DD" \
        -F "method_free=$FORM_METHOD_F" \
        -F "method_premium=$FORM_METHOD_P" \
        "$URL") || return

    # <div class="err">Skipped countdown</div>
    if match '<div class="err"' "$PAGE"; then
        ERR=$(echo "$PAGE" | parse_tag 'class="err"' div)
        log_error "Remote error: $ERR"
    else
        FILE_NAME=$(echo "$PAGE" | parse_tag '"style1"' span) || return
        FILE_URL=$(echo "$PAGE" | parse_attr '/d/' href) || return

        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0
    fi

    return $ERR_FATAL
}

# Upload a file to filebox
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download_url
180upload_upload() {
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://180upload.com/'
    local -r MAX_SIZE=2147483648 # 2GiB
    local PAGE UPLOAD_ID USER_TYPE DL_URL DEL_URL
    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_TMP_SRV

    # Check for forbidden file extensions
    case ${DEST_FILE##*.} in
        php|pl|cgi|py|sh|shtml)
            log_error 'File extension is forbidden. Try renaming your file.'
            return $ERR_FATAL
            ;;
    esac

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    PAGE=$(curl -L -b 'lang=english' "$BASE_URL") || return

    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_UTYPE=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_type')
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id')
    FORM_TMP_SRV=$(echo "$FORM_HTML" | parse_form_input_by_name 'srv_tmp_url') || return
    log_debug "Server URL: '$FORM_TMP_SRV'"

    UPLOAD_ID=$(random dec 12)
    USER_TYPE=anon

    PAGE=$(curl "${FORM_TMP_SRV}/status.html?${UPLOAD_ID}=$DEST_FILE=180upload.com") || return

    # Sanity check. Avoid failure after effective upload
    if match '>404 Not Found<' "$PAGE"; then
        log_error "upstream error (404)"
        return $ERR_FATAL
    fi

    PAGE=$(curl_with_log \
       -F "upload_type=$FORM_UTYPE" \
       -F "sess_id=$FORM_SESS" \
       -F "srv_tmp_url=$FORM_TMP_SRV" \
       -F "file_0=@$FILE;filename=$DEST_FILE" \
       --form-string "file_0_descr=$DESCRIPTION" \
       -F "file_1=@/dev/null;filename=" \
       -F 'tos=1' \
       -F "link_rcpt=$TOEMAIL" \
       -F 'submit_btn= Upload! ' \
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

        DL_URL=$(echo "$PAGE" | parse 'Download Link' '>\(http[^<]\+\)<' 1) || return
        DEL_URL=$(echo "$PAGE" | parse 'Delete Link' '>\(http[^<]\+\)<' 1)

        echo "$DL_URL"
        echo "$DEL_URL"
        return 0
    fi

    log_error "Unexpected status: $FORM2_ST"
    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: 180upload url
# $3: requested capability list
# stdout: 1 capability per line
180upload_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT

    PAGE=$(curl -L -b 'lang=english' "$URL") || return

    # File Not Found, Copyright infringement issue, file expired or deleted by its owner.
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'center nowrap' b <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    echo $REQ_OUT
}
