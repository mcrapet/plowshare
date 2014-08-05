# Plowshare zalaa.com module
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
# Note: This module is similar to ryushare.

MODULE_ZALAA_REGEXP_URL='https\?://\(www\.\)\?zalaa\.com/'

MODULE_ZALAA_DOWNLOAD_OPTIONS=""
MODULE_ZALAA_DOWNLOAD_RESUME=yes
MODULE_ZALAA_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_ZALAA_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_ZALAA_UPLOAD_OPTIONS="
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_ZALAA_UPLOAD_REMOTE_SUPPORT=no

MODULE_ZALAA_LIST_OPTIONS=""
MODULE_ZALAA_LIST_HAS_SUBFOLDERS=yes

MODULE_ZALAA_PROBE_OPTIONS=""

# Output a zalaa file download URL
# $1: cookie file (unused here)
# $2: zalaa url
# stdout: real file download link
zalaa_download() {
    local URL=$2
    local PAGE FILE_URL JS_CODE JS_CODE2
    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_METHOD FORM_COUNT

    PAGE=$(curl -L -b 'lang=english' "$URL") || return

    # The file you were looking for could not be found, sorry for any inconvenience
    # This file has been removed due to Copyright infringement
    if match 'File Not Found\|Copyright infringement' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi


    detect_javascript || return

    FORM_HTML=$(grep_form_by_name "$PAGE" frmdownload) || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname')
    FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')
    FORM_COUNT=$(echo "$FORM_HTML" | parse_form_input_by_name 'ipcount_val')

    PAGE=$(curl -b 'lang=english' -d 'referer=' \
        -d "op=$FORM_OP" \
        -d "usr_login=$FORM_USR" \
        -d "id=$FORM_ID" \
        -d "fname=$FORM_FNAME" \
        -d "method_free=$FORM_METHOD" \
        -d "ipcount_val=$FORM_COUNT" "$URL") || return

    FILE_URL=$(echo "$PAGE" | parse_attr 'btndnlbt"' href) || return

    # Note: referer is required
    PAGE=$(curl -b 'lang=english' --referer "$URL" "$FILE_URL") || return

    # Obfuscated javascript
    JS_CODE=$(echo "$PAGE" | parse 'split(' '>\(.*\)$') || return
    JS_CODE2=$(echo "eval = function(x) { print(x); }; $JS_CODE" | javascript) || return

    FILE_URL=$(echo "$JS_CODE2" | parse 'location\.href' "f='\([^']*\)") || return

    echo "$FILE_URL"
    echo "$FORM_FNAME"
}

# Upload a file to zalaa.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
zalaa_upload() {
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://www.zalaa.com'

    local PAGE UPLOAD_ID USER_TYPE DL_URL DEL_URL
    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_UHOST FORM_SESS FORM_TMP_SRV

    PAGE=$(curl -L -b 'lang=english' "$BASE_URL") || return

    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_UTYPE=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_type')
    FORM_UHOST=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_host')
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id')
    FORM_TMP_SRV=$(echo "$FORM_HTML" | parse_form_input_by_name 'srv_tmp_url') || return

    UPLOAD_ID=$(random dec 12)
    USER_TYPE=anon

    PAGE=$(curl "${FORM_TMP_SRV}/status.html?${UPLOAD_ID}=filename=www.zalaa.com") || return

    # Sanity check. Avoid failure after effective upload
    if match '>404 Not Found<' "$PAGE"; then
        log_error 'upstream error (404)'
        return $ERR_FATAL
    fi

    # xupload.js
    PAGE=$(curl_with_log -F 'tos=1' \
        -H 'Expect: ' \
        -F "upload_type=$FORM_UTYPE" \
        -F "upload_host=$FORM_HOST" \
        -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        --form-string "file_0_descr=$DESCRIPTION" \
        -F "file_1=@/dev/null;filename=" \
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
        PAGE=$(curl -b 'lang=english' \
            -d "fn=$FORM2_FN" -d "st=$FORM2_ST" -d "op=$FORM2_OP" \
            "$FORM2_ACTION") || return

        DL_URL=$(echo "$PAGE" | parse 'Download Link' '">\([^<]*\)' 1) || return
        DEL_URL="" # N/A

        echo "$DL_URL"
        echo "$DEL_URL"
        echo "$LINK_PASSWORD"
        return 0
    fi

    log_error "Unexpected status: $FORM2_ST"
    return $ERR_FATAL
}

# List a zalaa shared file folder URL
# $1: zalaa url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
zalaa_list() {
    local URL=$1
    local PAGE NAMES LINKS

    # check whether it looks like a folder link
    if ! match "${MODULE_ZALAA_REGEXP_URL}users/" "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    test "$2" && log_error "Recursive flag not implemented, ignoring"

    PAGE=$(curl -L "$URL") || return

    LINKS=$(echo "$PAGE" | parse_all_quiet 'class=.file_block' 'href="\([^"]*\)' 2)
    NAMES=$(echo "$PAGE" | parse_all_quiet 'class=.file_block' '">\([^<]*\)' 2)

    list_submit "$LINKS" "$NAMES" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: zalaa url
# $3: requested capability list
# stdout: 1 capability per line
zalaa_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L -b 'lang=english' "$URL") || return

    # The file you were looking for could not be found, sorry for any inconvenience
    # This file has been removed due to Copyright infringement
    if match 'File Not Found\|Copyright infringement' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_form_input_by_name 'fname' <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse '>File Size[[:space:]]*:<' \
            '^\(.*\)$' 1) && translate_size "$FILE_SIZE" && \
                REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
