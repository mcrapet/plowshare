#!/bin/bash
#
# billionuploads.com module
# Copyright (c) 2012-2013 sapk <at> sapk.fr
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
# Note: This module is similar to 180upload

MODULE_BILLIONUPLOADS_REGEXP_URL='https\?://\(www\.\)\?[Bb]illion[Uu]ploads\.com/'

MODULE_BILLIONUPLOADS_DOWNLOAD_OPTIONS=""
MODULE_BILLIONUPLOADS_DOWNLOAD_RESUME=yes
MODULE_BILLIONUPLOADS_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_BILLIONUPLOADS_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_BILLIONUPLOADS_UPLOAD_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_BILLIONUPLOADS_UPLOAD_REMOTE_SUPPORT=no

MODULE_BILLIONUPLOADS_PROBE_OPTIONS=""

# Output a billionuploads.com file download URL and NAME
# $1: cookie file
# $2: billionuploads.com url
# stdout: real file download link and name
billionuploads_download() {
    local -r COOKIEFILE=$1
    local -r URL=$2
    local PAGE FILE_NAME FILE_URL ERR
    local FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_DD FORM_METHOD_F FORM_METHOD_P CRYPT

    PAGE=$(curl -L -b "$COOKIEFILE" "$URL") || return

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

    PAGE=$(curl -b "$COOKIE_FILE" \
        -F "referer=" \
        -F "op=$FORM_OP" \
        -F "id=$FORM_ID" \
        -F "rand=$FORM_RAND" \
        -F "down_direct=$FORM_DD" \
        -F "method_free=$FORM_METHOD_F" \
        -F "method_premium=$FORM_METHOD_P" \
        -F "geekref=yeahman" \
        "$URL"  | break_html_lines ) || return

    # Catch the error "the file is temporary unavailable".
    if match 'file is temporarily unavailable - please try again later' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # <div class="err">Skipped countdown</div>
    if match '<div class="err"' "$PAGE"; then
        ERR=$(echo "$PAGE" | parse_tag 'class="err"' div)
        log_error "Remote error: $ERR"
        return $ERR_FATAL
    fi

    CRYPT=$(echo "$PAGE" | parse 'subway="metro"' 'subway="metro">[^<]*XXX\([^<]\+\)XXX[^<]*') || return
    if ! match '^[[:alnum:]=]\+$' "$CRYPT"; then
        log_error "Something wrong with encoded message."
        return $ERR_FATAL
    fi

    FILE_URL=$(echo "$CRYPT" | base64 -d | base64 -d)

    echo "$FILE_URL"
}

# Upload a file to billionuploads
# $1: cookie file (not used here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download_url
billionuploads_upload() {
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://billionuploads.com/'
    local -r MAX_SIZE=2147483648 # 2GiB
    local PAGE UPLOAD_ID USER_TYPE DL_URL DEL_URL
    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_TMP_SRV FILE_CODE STATE

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

    PAGE=$(curl -L "$BASE_URL") || return

    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_UTYPE=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_type')
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id')
    FORM_TMP_SRV=$(echo "$FORM_HTML" | parse_form_input_by_name 'srv_tmp_url') || return
    log_debug "Server URL: '$FORM_TMP_SRV'"

    UPLOAD_ID=$(random dec 12)
    USER_TYPE=''

    PAGE=$(curl "${FORM_TMP_SRV}/status.html?${UPLOAD_ID}=$DEST_FILE=billionuploads.com") || return

    # Sanity check. Avoid failure after effective upload
    if match '>404 Not Found<' "$PAGE"; then
        log_error 'upstream error (404)'
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
        --form-string "link_rcpt=$TOEMAIL" \
        --form-string "link_pass=$LINK_PASSWORD" \
        -F 'submit_btn= Upload! ' \
        "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=$FORM_UTYPE" | \
        break_html_lines) || return

    FILE_CODE=$(echo "$PAGE" | parse 'fc-X-x-' 'fc-X-x-\([^"]\+\)')
    STATE=$(echo "$PAGE" | parse 'st-X-x-' 'st-X-x-\([^"]\+\)')

    if [ "$STATE" = 'OK' ]; then
        echo "$BASE_URL$FILE_CODE"
        return 0
    fi

    log_error "Unexpected status: $STATE"
    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file
# $2: bitshare url
# $3: requested capability list
# stdout: 1 capability per line
billionuploads_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_NAME FILE_SIZE

    PAGE=$(curl -L "$URL") || return

    ! match 'File Not Found' "$PAGE" || return $ERR_LINK_DEAD

    REQ_OUT=c

    # Filename can be truncated
    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(echo "$PAGE" | parse_quiet '>File Name:<' 'class="dofir"[^>]*>\([^<]*\)' 1)
        test "$FILE_NAME" && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse_quiet '>File Size:<' 'class="dofir"[^>]*>\([^<]*\)' 1)
        test "$FILE_SIZE" && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
