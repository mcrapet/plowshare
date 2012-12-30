#!/bin/bash
#
# billionuploads.com module
# Copyright (c) 2012 xeros.78<at>gmail.com
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
