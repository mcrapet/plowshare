# Plowshare fshare.vn module
# Copyright (c) 2013-2014 Plowshare team
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

MODULE_FSHARE_VN_REGEXP_URL='http://\(www\.\)\?fshare\.vn/\(file\|folder\)/[[:alnum:]]\+'

MODULE_FSHARE_VN_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_FSHARE_VN_DOWNLOAD_RESUME=yes
MODULE_FSHARE_VN_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FSHARE_VN_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FSHARE_VN_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
FOLDER,,folder,s=FOLDER,Folder to upload files into
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_FSHARE_VN_UPLOAD_REMOTE_SUPPORT=no

MODULE_FSHARE_VN_LIST_OPTIONS=""
MODULE_FSHARE_VN_LIST_HAS_SUBFOLDERS=no

MODULE_FSHARE_VN_PROBE_OPTIONS=""

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
fshare_vn_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT LOCATION

    LOGIN_DATA='login_useremail=$USER&login_password=$PASSWORD&url_refe=http://www.fshare.vn/'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.php" \
        -e "$BASE_URL/login.php" \
        -i) || return

    LOCATION=$(grep_http_header_location_quiet <<< "$LOGIN_RESULT")

    if [ "$LOCATION" != 'http://www.fshare.vn/' ]; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a fshare.vn file download URL
# $1: cookie file
# $2: fshare.vn url
# stdout: real file download link
fshare_vn_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(replace '://fshare' '://www.fshare' <<< "$2")

    local PAGE LOCATION FILE_URL WAIT_TIME
    local FORM_HTML FORM_ACTION FORM_FILE_ID FORM_SPECIAL FORM_PASSWORD

    if [ -n "$AUTH" ]; then
        fshare_vn_login "$AUTH" "$COOKIE_FILE" 'https://www.fshare.vn' || return
    fi

    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    # Files from user account download directly (maybe like premium)
    if match '/download/' "$LOCATION"; then
        echo "$LOCATION"
        return 0
    fi

    if match 'Liên kết bạn chọn không tồn tại trên hệ thống' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_ACTION=$(parse_form_input_by_name 'action' <<< "$FORM_HTML") || return
    FORM_FILE_ID=$(parse_form_input_by_name 'file_id' <<< "$FORM_HTML") || return
    FORM_SPECIAL=$(parse_form_input_by_name_quiet 'special' <<< "$FORM_HTML")

    if match 'Vui lòng nhập mật khẩu để tải tập tin' "$PAGE"; then
        log_debug 'File is password protected.'

        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        FORM_PASSWORD="-d link_file_pwd_dl=$LINK_PASSWORD"
    fi

    PAGE=$(curl -b "$COOKIE_FILE" \
        $FORM_PASSWORD \
        -d "action=$FORM_ACTION" \
        -d "file_id=$FORM_FILE_ID" \
        -d "special=$FORM_SPECIAL" \
        "$URL") || return

    if match 'Mật khẩu download file không đúng' "$PAGE"; then
        return $ERR_LINK_PASSWORD_REQUIRED
    fi

    FILE_URL=$(parse_attr '<form' 'action' <<< "$PAGE") || return
    FILE_URL=$(replace_all '#download' '' <<< "$FILE_URL")

    WAIT_TIME=$(parse 'var count = ' 'var count = \([0-9]\+\)' <<< "$PAGE") || return
    wait $WAIT_TIME || return

    echo "$FILE_URL"
}

# Upload a file to fshare.vn
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
fshare_vn_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://up.fshare.vn'
    local -r MAX_SIZE=524288000 # 500 MiB

    local PAGE FOLDERS FOLDER_ID ERROR FORM_PASSWORD_OPT FORM_TOEMAIL_OPT FORM_SESSID LINK_DL

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    local FILE_SIZE=$(get_filesize "$FILE")
    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    fshare_vn_login "$AUTH" "$COOKIE_FILE" 'https://www.fshare.vn' || return

    if [ -n "$FOLDER" ]; then
        log_debug 'Getting folder ID...'

        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/index.php") || return

        FOLDERS=$(parse_all_tag_quiet 'option' <<< "$PAGE") || return
        FOLDERS=$(delete_first_line <<< "$FOLDERS")

        if ! match "^$FOLDER$" "$FOLDERS"; then
            log_debug "Creating folder '$FOLDER'..."

            PAGE=$(curl -b "$COOKIE_FILE" -G \
                -d 'action=a_folder' \
                -d "f_name=$FOLDER" \
                "$BASE_URL/index.php") || return

            ERROR=$(parse_json 'error_no' <<< "$PAGE") || return

            if [ "$ERROR" != "0" ]; then
                log_error 'Could not create folder.'
            else
                PAGE=$(parse_json 'result' <<< "$PAGE") || return
            fi
        fi

        PAGE=$(break_html_lines <<< "$PAGE")
        FOLDER_ID=$(parse_attr "<option[^<]*>$FOLDER</option>" 'value' <<< "$PAGE") || return

        log_debug "Folder ID: '$FOLDER_ID'"
    else
        FOLDER_ID="-1"
    fi

    [ -n "$LINK_PASSWORD" ] && \
        FORM_PASSWORD_OPT="--form-string filepwd=$LINK_PASSWORD"

    [ -n "$TOEMAIL" ] && \
        FORM_TOEMAIL_OPT="--form-string emailto=$TOEMAIL"

    [ -z "$DESCRIPTION" ] && \
        DESCRIPTION='null'

    FORM_SESSID=$(parse_cookie 'PHPSESSID' < "$COOKIE_FILE") || return

    PAGE=$(curl_with_log \
        -F "Filename=$DEST_FILE" \
        $FORM_PASSWORD_OPT \
        --form-string "desc=$DESCRIPTION" \
        -F "folderid=$FOLDER_ID" \
        -F 'secure=null' \
        -F "SESSID=$FORM_SESSID" \
        $FORM_TOEMAIL_OPT \
        -F 'direct_link=null' \
        -F "fileupload=@$FILE;filename=$DEST_FILE" \
        -F 'Upload=Submit Query' \
        "$BASE_URL/upload.php") || return

    if ! match_remote_url "$PAGE"; then
        log_error 'Upload failed.'
        return $ERR_FATAL
    else
        LINK_DL="$PAGE"
    fi

    if [ -n "$TOEMAIL" ]; then
        PAGE=$(curl -b "$COOKIE_FILE" \
            "$BASE_URL/sendmail.php") || return

        if [ "$PAGE" != '1' ]; then
            log_error 'Could not send link.'
        fi
    fi

    echo "$LINK_DL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: fshare.vn url
# $3: requested capability list
# stdout: 1 capability per line
fshare_vn_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -L "$URL") || return

    if match 'Liên kết bạn chọn không tồn tại trên hệ thống' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse 'Tên tập tin' '</b> \([^<]\+\)' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'Dung lượng' '</b> \([^<]\+\)' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a fshare.vn web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
fshare_vn_list() {
    local -r URL=$1
    local -r REC=$2

    local PAGE LINKS NAMES

    PAGE=$(curl -L "$URL") || return

    LINKS=$(parse_all_attr_quiet 'filename' 'href' <<< "$PAGE")
    NAMES=$(parse_all_tag_quiet 'filename' 'span' <<< "$PAGE")

    list_submit "$LINKS" "$NAMES"
}
