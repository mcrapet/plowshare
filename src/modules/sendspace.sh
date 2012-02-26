#!/bin/bash
#
# sendspace.com module
# Copyright (c) 2010-2012 Plowshare team
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

MODULE_SENDSPACE_REGEXP_URL="http://\(www\.\)\?sendspace\.com/\(file\|folder\|delete\)/"

MODULE_SENDSPACE_DOWNLOAD_OPTIONS=""
MODULE_SENDSPACE_DOWNLOAD_RESUME=yes
MODULE_SENDSPACE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

MODULE_SENDSPACE_UPLOAD_OPTIONS="
DESCRIPTION,d:,description:,DESCRIPTION,Set file description"
MODULE_SENDSPACE_UPLOAD_REMOTE_SUPPORT=no

MODULE_SENDSPACE_DELETE_OPTIONS=""
MODULE_SENDSPACE_LIST_OPTIONS=""

# Output a sendspace file download URL
# $1: cookie file (unused here)
# $2: sendspace.com url
# stdout: real file download link
sendspace_download() {
    local URL=$2
    local PAGE FILE_URL

    if match 'sendspace\.com/folder/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return $ERR_FATAL
    fi

    PAGE=$(curl "$URL") || return

    # - Sorry, the file you requested is not available.
    if match '<div class="msg error"' "$PAGE"; then
        local ERR=$(echo "$PAGE" | parse '="msg error"' '">\([^<]*\)')
        log_error "$ERR"
        return $ERR_LINK_DEAD
    fi

    PAGE=$(curl --referer "$URL" "$URL") || return
    FILE_URL=$(echo "$PAGE" | parse_attr 'download_button' 'href') || return

    test "$CHECK_LINK" && return 0

    echo "$FILE_URL"
}

# Upload a file to sendspace.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: sendspace.com download + delete link
sendspace_upload() {
    eval "$(process_options sendspace "$MODULE_SENDSPACE_UPLOAD_OPTIONS" "$@")"

    local FILE=$2
    local DESTFILE=$3
    local SZ=$(get_filesize "$FILE")
    local DATA DL_LINK DEL_LINK

    # Warning message
    if [ "$SZ" -gt 314572800 ]; then
        log_error "warning: file is bigger than 300MB, site may not support it"
    fi

    DATA=$(curl 'http://www.sendspace.com') || return

    local FORM_HTML FORM_URL FORM_MAXFSIZE FORM_UID FORM_DDIR FORM_JSEMA FORM_SIGN FORM_UFILES FORM_TERMS
    FORM_HTML=$(grep_form_by_order "$DATA" 3 | break_html_lines_alt)
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action)
    FORM_MAXFSIZE=$(echo "$FORM_HTML" | parse_form_input_by_name 'MAX_FILE_SIZE')
    FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'UPLOAD_IDENTIFIER')
    FORM_DDIR=$(echo "$FORM_HTML" | parse_form_input_by_name 'DESTINATION_DIR')
    FORM_JSENA=$(echo "$FORM_HTML" | parse_form_input_by_name 'js_enabled')
    FORM_SIGN=$(echo "$FORM_HTML" | parse_form_input_by_name 'signature')
    FORM_UFILES=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_files')
    FORM_TERMS=$(echo "$FORM_HTML" | parse_form_input_by_name 'terms')

    DATA=$(curl_with_log \
        -F "MAX_FILE_SIZE=$FORM_MAXFSIZE" \
        -F "UPLOAD_IDENTIFIER=$FORM_UID"  \
        -F "DESTINATION_DIR=$FORM_DDIR"   \
        -F "js_enabled=$FORM_JSENA"       \
        -F "signature=$FORM_SIGN"         \
        -F "upload_files=$FORM_UFILES"    \
        -F "terms=$FORM_TERMS"            \
        -F "file[]="                      \
        -F "ownemail="                    \
        -F "recpemail="                   \
        -F "upload_file[]=@$FILE;filename=$DESTFILE" \
        --form-string "description[]=$DESCRIPTION"   \
        "$FORM_URL") || return

    if [ -z "$DATA" ]; then
        log_error "upload unsuccessful"
        return $ERR_FATAL
    fi

    DL_LINK=$(echo "$DATA" | parse_attr 'share link' 'href') || return
    DEL_LINK=$(echo "$DATA" | parse_attr '\/delete\/' 'href') || return

    echo "$DL_LINK"
    echo "$DEL_LINK"
}

# Delete a file on sendspace
# $1: delete link
sendspace_delete() {
    eval "$(process_options sendspace "$MODULE_SENDSPACE_DELETE_OPTIONS" "$@")"

    local URL=$1
    local PAGE FORM_HTML FORM_URL FORM_SUBMIT

    PAGE=$(curl "$URL") || return

    if match 'You are about to delete the folowing file' "$PAGE"; then
        FORM_HTML=$(grep_form_by_order "$PAGE" 3)
        FORM_URL=$(echo "$FORM_HTML" | parse_form_action)
        FORM_SUBMIT=$(echo "$FORM_HTML" | parse_form_input_by_name 'delete')

        PAGE=$(curl -F "submit=$FORM_SUBMIT" $FORM_URL) || return

        if ! match 'file has been successfully deleted' "$PAGE"; then
            return $ERR_FATAL
        fi

    # Error, the deletion code you provided is incorrect or incomplete. Please make sure to use the full link.
    else
        log_error "bad deletion code"
        return $ERR_FATAL
    fi

    return 0
}

# List a sendspace shared folder
# $1: sendspace folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links (file and/or folder)
sendspace_list() {
    eval "$(process_options sendspace "$MODULE_SENDSPACE_LIST_OPTIONS" "$@")"

    local URL=$1
    local PAGE LINKS SUBDIRS FILE_NAME FILE_URL

    if ! match 'sendspace\.com/folder/' "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    PAGE=$(curl "$URL") || return
    LINKS=$(echo "$PAGE" | parse_all_quiet \
        '<td class="dl" align="center"' '\(<a href="http[^<]*<\/a>\)')
    SUBDIRS=$(echo "$PAGE" | parse_all_quiet \
        '\/folder\/' '\(<a href="http[^<]*<\/a>\)')

    if [ -z "$LINKS" -a -z "$SUBDIRS" ]; then
        return $ERR_LINK_DEAD
    fi

    # Stay at depth=1 (we do not recurse into directories)
    if test "$2"; then
        log_debug "recursive flag is not fully supported"
        LINKS=$(echo "$LINKS" "$SUBDIRS")
    fi

    # First pass : print debug message
    while read LINE; do
        FILE_NAME=$(echo "$LINE" | parse_attr 'a' 'title')
        log_debug "$FILE_NAME"
    done <<< "$LINKS"

    # Second pass : print links (stdout)
    while read LINE; do
        FILE_URL=$(echo "$LINE" | parse_attr 'a' 'href')
        echo "$FILE_URL"
    done <<< "$LINKS"
}
