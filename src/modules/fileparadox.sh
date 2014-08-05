# Plowshare fileparadox.in module
# Copyright (c) 2014 Plowshare team
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

MODULE_FILEPARADOX_REGEXP_URL='https\?://\(www\.\)\?fileparadox\.in/'

MODULE_FILEPARADOX_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_FILEPARADOX_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
fileparadox_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT STATUS NAME

    LOGIN_DATA='op=login&login=$USER&password=$PASSWORD&redirect='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA$BASE_URL/?op=my_account" \
        "$BASE_URL" -L -b 'lang=english') || return

    # If successful, two entries are added into cookie file: login and xfss
    STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
    if [ -z "$STATUS" ]; then
        return $ERR_LOGIN_FAILED
    fi

    NAME=$(parse_cookie 'login' < "$COOKIE_FILE")
    log_debug "Successfully logged in as $NAME member"
}

# Upload a file to fileparadox.in
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
fileparadox_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://fileparadox.in'
    local PAGE UPLOAD_ID USER_TYPE

    # Sanity check
    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS

    fileparadox_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -c "$COOKIE_FILE" -b 'lang=english' -b "$COOKIE_FILE" "$BASE_URL") || return

    local FORM_HTML FORM_ACTION FORM_TMP_SRV FORM_UTYPE FORM_SESS
    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_TMP_SRV=$(echo "$FORM_HTML" | parse_form_input_by_name 'srv_tmp_url') || return
    FORM_UTYPE=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_type') || return
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id') || return

    UPLOAD_ID=$(random dec 12)
    USER_TYPE=reg

    PAGE=$(curl_with_log \
        -F "upload_type=$FORM_UTYPE" \
        -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        --form-string "link_rcpt=$TOEMAIL" \
        --form-string "link_pass=$LINK_PASSWORD" \
        -F 'tos=1' \
        -F 'submit_btn=' \
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
            "$FORM2_ACTION" | break_html_lines) || return

        DL_URL=$(parse 'Download Link' '>\(.*\)$' 2 <<< "$PAGE") || return
        DEL_URL=$(parse 'Delete Link' '>\(.*\)$' 2 <<< "$PAGE")

        echo "$DL_URL"
        echo "$DEL_URL"
        echo "$LINK_PASSWORD"
        return 0
    fi

    log_error "Unexpected status: $FORM2_ST"
    return $ERR_FATAL
}
