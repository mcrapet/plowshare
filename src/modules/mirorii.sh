#!/bin/bash
#
# mirorii.com module
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
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_MIRORII_REGEXP_URL="http://\(www\.\)\?mirorii\.com/"

MODULE_MIRORII_UPLOAD_OPTIONS="
DESCRIPTION,d,description,S=DESCRIPTION,Set file description"
MODULE_MIRORII_UPLOAD_REMOTE_SUPPORT=no

MODULE_MIRORII_LIST_OPTIONS=""

# Upload a file to Mirorii
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: mirorii.com download link
mirorii_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://www.mirorii.com'
    local PAGE FORM_HTML FORM_ACTION FORM_PBMODE FORM_EXTFOLDER UPLOAD_ID

    PAGE=$(curl "$BASE_URL") || return

    FORM_HTML=$(grep_form_by_id "$PAGE" myform) || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_PBMODE=$(echo "$FORM_HTML" | parse_form_input_by_name 'pbmode') || return
    FORM_EXTFOLDER=$(echo "$FORM_HTML" | parse_form_input_by_name 'ext_folder') || return

    # var UID = Math.round(10000*Math.random())+'0'+Math.round(10000*Math.random());
    UPLOAD_ID=$(random dec 4)0$(random dec 4)

    PAGE=$(curl_with_log \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        --form-string "file_0_descr=$DESCRIPTION" \
        --form-string "ext_folder=$FORM_EXTFOLDER" \
        --form-string "pbmode=$FORM_PBMODE" \
        "$BASE_URL$FORM_ACTION?upload_id=$UPLOAD_ID&js_on=1&xpass=&xmode=1" | \
        break_html_lines) || return

    local FORM2_ACTION FORM2_FN FORM2_FN_ORIG FORM2_STATUS FORM2_SIZE FORM2_DESCR
    local FORM2_MIME FORM2_NB FORM2_DURATION FORM2_EXTFOLDER

    FORM2_ACTION=$(echo "$PAGE" | parse_form_action) || return
    FORM2_FN=$(echo "$PAGE" | parse_tag 'file_name\[\].>' textarea)
    FORM2_FN_ORIG=$(echo "$PAGE" | parse_tag 'file_name_orig\[\].>' textarea)
    FORM2_STATUS=$(echo "$PAGE" | parse_tag 'file_status\[\].>' textarea)
    FORM2_SIZE=$(echo "$PAGE" | parse_tag 'file_size\[\].>' textarea)
    FORM2_DESCR=$(echo "$PAGE" | parse_tag_quiet 'file_descr\[\].>' textarea)
    FORM2_MIME=$(echo "$PAGE" | parse_tag 'file_mime\[\].>' textarea)
    FORM2_NB=$(echo "$PAGE" | parse_tag 'number_of_files.>' textarea)
    FORM2_DURATION=$(echo "$PAGE" | parse_tag 'duration.>' textarea)
    FORM2_EXTFOLDER=$(echo "$PAGE" | parse_tag 'ext_folder.>' textarea)

    if [ "$FORM2_STATUS" = 'OK' ]; then
        PAGE=$(curl \
            -d "file_name%5B%5D=$FORM2_FN" \
            -d "file_name_orig%5B%5D=$FORM2_FN_ORIG" \
            -d "file_status%5B%5D=$FORM2_STATUS" \
            -d "file_size%5B%5D=$FORM2_SIZE" \
            -d "file_descr%5B%5D=$FORM2_DESCR" \
            -d "file_mime%5B%5D=$FORM2_MIME" \
            -d "number_of_files=$FORM2_NB" \
            -d "duration=$FORM2_DURATION" \
            -d "ext_folder=$FORM2_EXTFOLDER" \
            -d "ip=10.10.48.48" \
            -d "host=undefined" \
            "$FORM2_ACTION") || return

        echo "$PAGE" | parse 'textarea' '>\(http.*\)$' || return
        return 0
    fi

    log_error "Unexpected status: $FORM2_STATUS"
    return $ERR_FATAL
}

# List links from a Mirorii link
# $1: mirorii link
# $2: recurse subfolders (ignored here)
# stdout: list of links
mirorii_list() {
    local -r URL=$1
    local PAGE LINKS_URL COOKIE_FILE NAMES H LINK

    if test "$2"; then
        log_error "Recursive flag has no sense here, abort"
        return $ERR_BAD_COMMAND_LINE
    fi

    COOKIE_FILE=$(create_tempfile) || return

    # Get PHPSESSID cookie entry (required later)
    PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return
    LINKS_URL=$(echo "$PAGE" | parse_attr 'upload-url' href) || return

    PAGE=$(curl -b "$COOKIE_FILE" "$LINKS_URL" | break_html_lines) || return
    rm -f "$COOKIE_FILE"

    NAMES=$(echo "$PAGE" | parse_all 'Ajax.\PeriodicalUpdater' "('\([^']*\)") || return
    log_debug "Parsed hosters: '"$NAMES"'"

    for H in $NAMES; do
        LINK=$(echo "$PAGE" | parse_attr_quiet "id=.${H}." href)
        if [ -n "$LINK" ]; then
            echo "$LINK"
            echo "$H"
        else
            log_debug "hoster $H not uploaded"
        fi
    done
}
