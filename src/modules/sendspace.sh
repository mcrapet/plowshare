# Plowshare sendspace.com module
# Copyright (c) 2010-2013 Plowshare team
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

MODULE_SENDSPACE_REGEXP_URL='https\?://\(www\.\)\?sendspace\.com/\(file\|folder\|delete\)/'

MODULE_SENDSPACE_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_SENDSPACE_DOWNLOAD_RESUME=yes
MODULE_SENDSPACE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_SENDSPACE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_SENDSPACE_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
DESCRIPTION,d,description,S=DESCRIPTION,Set file description"
MODULE_SENDSPACE_UPLOAD_REMOTE_SUPPORT=no

MODULE_SENDSPACE_LIST_OPTIONS=""
MODULE_SENDSPACE_LIST_HAS_SUBFOLDERS=yes

MODULE_SENDSPACE_DELETE_OPTIONS=""
MODULE_SENDSPACE_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
sendspace_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA STATUS USER

    # Note: "remember=on" not needed
    LOGIN_DATA='action=login&submit=login&target=%2F&action_type=login&remember=1&username=$USER&password=$PASSWORD'
    post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.html" -o /dev/null || return

    STATUS=$(parse_cookie_quiet 'ssal' < "$COOKIE_FILE")
    if [ -z "$STATUS" -o "$STATUS" = 'deleted' ]; then
        return $ERR_LOGIN_FAILED
    fi

    split_auth "$AUTH" USER || return
    log_debug "Successfully logged in as member '$USER'"
}

# Output a sendspace file download URL
# $1: cookie file
# $2: sendspace.com url
# stdout: real file download link
sendspace_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='https://www.sendspace.com'
    local PAGE

    if match "${BASE_URL#*/}/folder/" "$URL"; then
        log_error 'This is a directory list, use plowlist!'
        return $ERR_FATAL
    fi

    if [ -n "$AUTH" ]; then
        sendspace_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -L -b "$COOKIE_FILE" "$URL") || return

    if match '<div class="msg error"' "$PAGE"; then
        local ERR=$(echo "$PAGE" | parse_tag 'class="msg error"' 'div') || return

        # Sorry, the file you requested is not available.
        if match 'file you requested is not available' "$ERR"; then
            return $ERR_LINK_DEAD
        fi

        log_error "Remote error: $ERR"
        return $ERR_FATAL
    fi


    # parse and output URL and file name
    echo "$PAGE" | parse_attr 'download_button' 'href' || return
    echo "$PAGE" | parse_tag 'class="bgray"' 'b' || return
}

# Upload a file to sendspace.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: sendspace.com download + delete link
sendspace_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='https://www.sendspace.com'
    local PAGE SIZE MAXSIZE OPT_USER OPT_FOLDER
    local FORM_HTML FORM_URL FORM_PROG_URL FORM_DEST_DIR FORM_SIG FORM_MAIL

    if [ -n "$AUTH" ]; then
        sendspace_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return

    FORM_HTML=$(grep_form_by_order "$PAGE" -1 | break_html_lines_alt) || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    MAXSIZE=$(echo "$FORM_URL" | parse . 'MAX_FILE_SIZE=\([[:digit:]]\+\)') || return

    # File size limit check
    local SIZE=$(get_filesize "$FILE") || return
    if [ "$SIZE" -gt "$MAXSIZE" ]; then
        log_debug "File is bigger than $MAXSIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    FORM_PROG_URL=$(echo "$FORM_HTML" | parse_form_input_by_name 'PROGRESS_URL') || return
    FORM_SIG=$(echo "$FORM_HTML" | parse_form_input_by_name 'signature') || return

    if [ -n "$AUTH" ]; then
        local FORM_USER
        FORM_MAIL=$(echo "$FORM_HTML" | parse_form_input_by_name 'ownemail') || return
        FORM_USER=$(echo "$FORM_HTML" | parse_form_input_by_name 'userid') || return
        OPT_USER="-F userid=$FORM_USER"
        OPT_FOLDER='-F folder_id=0'
    fi

    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -F "PROGRESS_URL=$FORM_PROG_URL"              \
        -F 'js_enabled=1'                             \
        -F "signature=$FORM_SIG"                      \
        -F 'upload_files='                            \
        $OPT_USER                                     \
        -F 'terms=1'                                  \
        -F 'file[]='                                  \
        --form-string "description[]=$DESCRIPTION"    \
        -F "upload_file[]=@$FILE;filename=$DEST_FILE" \
        $OPT_FOLDER                                   \
        -F 'recpemail_fcbkinput=recipient@email.com'  \
        -F "ownemail=$FORM_MAIL"                      \
        -F 'recpemail='                               \
        "$FORM_URL") || return

    if [ -z "$PAGE" ] || match '403 Forbidden Request' "$PAGE"; then
        log_error 'Upload unsuccessful. Site updated?'
        return $ERR_FATAL
    fi

    # Parse and output download and delete link
    echo "$PAGE" | parse_attr 'share link' 'href' || return
    echo "$PAGE" | parse_attr '/delete/' 'href' || return
}

# Delete a file on sendspace
# $1: cookie file (unused here)
# $2: delete link
sendspace_delete() {
    local URL=$2
    local PAGE FORM_HTML FORM_URL FORM_SUBMIT

    PAGE=$(curl "$URL") || return

    if match 'You are about to delete the folowing file' "$PAGE"; then
        FORM_HTML=$(grep_form_by_order "$PAGE" 3)
        FORM_URL=$(echo "$FORM_HTML" | parse_form_action)
        FORM_SUBMIT=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'delete')

        PAGE=$(curl -F "submit=$FORM_SUBMIT" $FORM_URL) || return

        if ! match 'file has been successfully deleted' "$PAGE"; then
            return $ERR_FATAL
        fi

    # Error, the deletion code you provided is incorrect or incomplete. Please make sure to use the full link.
    else
        log_error 'Bad deletion code'
        return $ERR_FATAL
    fi

    return 0
}

# List a sendspace shared folder
# $1: sendspace folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links (file and/or folder)
sendspace_list() {
    local URL=$1
    local PAGE LINKS NAMES

    if ! match 'sendspace\.com/folder/' "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    test "$2" && log_error "Recursive flag not implemented, ignoring"

    PAGE=$(curl "$URL") || return

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'class="dl" align="center' href)
    NAMES=$(echo "$PAGE" | parse_all_attr_quiet 'class="dl" align="center' title)

    list_submit "$LINKS" "$NAMES" || return
}

# Probe a download URL
# $1: cookie file
# $2: sendspace url
# $3: requested capability list
# stdout: 1 capability per line
sendspace_probe() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L -c "$COOKIE_FILE" "$URL") || return

    if match '<div class="msg error"' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag '"bgray"' b <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse '>File Size:<' 'b>\(.*\)</div') && \
            translate_size "$FILE_SIZE" && \
                REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
