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

MODULE_BILLIONUPLOADS_REGEXP_URL="https\?://\(www\.\)\?[Bb]illion[Uu]ploads\.com/"

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
    local FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_DD FORM_METHOD_F FORM_METHOD_P

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

    # TODO extract exact time to wait to not trigger Skipped countdown error
    log_debug "Waiting 3 seconds to not trigger Skipped countdown error."
    wait 3 seconds

    PAGE=$(curl -b "$COOKIE_FILE" \
        -F "referer=" \
        -F "op=$FORM_OP" \
        -F "id=$FORM_ID" \
        -F "rand=$FORM_RAND" \
        -F "down_direct=$FORM_DD" \
        -F "method_free=$FORM_METHOD_F" \
        -F "method_premium=$FORM_METHOD_P" \
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

    FILE_NAME=$(echo "$PAGE" | parse_tag '<nobr>Filename:' b) || return
    FILE_URL=$(echo "$PAGE" | parse '<span id="link"' 'href="\([^"]\+\)"' 1) || return
    echo "$FILE_URL"
    echo "$FILE_NAME"
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
        -F "link_pass=$LINK_PASSWORD" \
        -F 'submit_btn= Upload! ' \
        "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=$FORM_UTYPE" | \
        break_html_lines) || return

    local FORM2_ACTION FORM2_FN FORM2_ST FORM2_OP FORM2_RCPT
    FORM2_ACTION=$(echo "$PAGE" | parse_form_action) || return
    FORM2_FN=$(echo "$PAGE" | parse_tag 'fn.>' textarea)
    FORM2_ST=$(echo "$PAGE" | parse_tag 'st.>' textarea)
    FORM2_OP=$(echo "$PAGE" | parse_tag 'op.>' textarea)
    FORM2_RCPT=$(echo "$PAGE" | parse_tag_quiet 'link_rcpt.>' textarea)

    if [ "$FORM2_ST" = 'OK' ]; then
        PAGE=$(curl -d "fn=$FORM2_FN" -d "st=$FORM2_ST" -d "op=$FORM2_OP" \
            -d "link_rcpt=$FORM2_RCPT" "$FORM2_ACTION") || return

        DL_URL=$(echo "$PAGE" | parse 'Long link' '\(http[^<]\+\)<' 1) || return
        DEL_URL=$(echo "$PAGE" | parse 'Delete Link' '>\(http[^<]\+\)<' 1)

        echo "$DL_URL"
        echo "$DEL_URL"
        return 0
    fi

    log_error "Unexpected status: $FORM2_ST"
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
        FILE_NAME=$(echo "$PAGE" | parse_quiet '>Filename:<' 'b>\([^<]*\)')
        test "$FILE_NAME" && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse_quiet '>Size:<' 'b>\([^<]*\)')
        test "$FILE_SIZE" && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
