#!/bin/bash
#
# zippyshare.com module
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

MODULE_ZIPPYSHARE_REGEXP_URL="https\?://\([[:alnum:]]\+\.\)\?zippyshare\.com/"

MODULE_ZIPPYSHARE_DOWNLOAD_OPTIONS=""
MODULE_ZIPPYSHARE_DOWNLOAD_RESUME=no
MODULE_ZIPPYSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_ZIPPYSHARE_UPLOAD_OPTIONS="
PRIVATE_FILE,,private,,Do not allow others to download the file"
MODULE_ZIPPYSHARE_UPLOAD_REMOTE_SUPPORT=no

# Output a zippyshare file download URL
# $1: cookie file (unused here)
# $2: zippyshare url
# stdout: real file download link
zippyshare_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local PAGE FILE_URL FILE_NAME PART1 PART2 N1 N2

    # JSESSIONID required
    PAGE=$(curl -c "$COOKIE_FILE" -b 'ziplocale=en' "$URL") || return

    # File does not exist on this server
    if match 'File does not exist' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    if match 'var[[:space:]]*submitCaptcha' "$PAGE"; then
        # reCaptcha is requested if you don't have flash v9
        # Otherwise, use DownloadButton_v1.14s.swf
        PART1=$(echo "$PAGE" | parse 'swfobject\.embedSWF' "url:[[:space:]]*'\([^']*\)") || return
        N1=$(echo "$PAGE" | parse 'swfobject\.embedSWF' 'seed:[[:space:]]*\([[:digit:]]*\)') || return
        FILE_URL="$PART1&time=$((5 * N1 % 71678963))"
    else
        # document.getElementById('dlbutton').href = "/d/91294633/"+(z)+"/foo.bar";
        PART1=$(echo "$PAGE" | parse '(z)' '"\(/d/[^"]*\)') || return
        PART2=$(echo "$PAGE" | parse '(z)' '+"\([^"]*\)') || return
        N1=$(echo "$PAGE" | parse '(z)' '=[[:space:]]*\([[:digit:]]\+\)[[:space:]]*+' -3)
        N2=$(echo "$PAGE" | parse '(z)' '+[[:space:]]*\([[:digit:]]\+\)[[:space:]]*;' -3)
        FILE_URL="$(basename_url "$URL")$PART1$((N1 + N2 - 7))$PART2"
    fi

    FILE_NAME=$(echo "$PAGE" | parse_quiet '>Name:[[:space:]]*<' '">\([^<]*\)')

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to zippyshare.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: zippyshare.com download link
zippyshare_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://www.zippyshare.com'
    local PAGE SERVER FORM_HTML FORM_ACTION FORM_UID FILE_URL FORM_DATA_PRIV

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt 209715200 ]; then
        log_debug "file is bigger than 200MB"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    PAGE=$(curl -L -b 'ziplocale=en' "$BASE_URL") || return

    SERVER=$(echo "$PAGE" | parse 'var[[:space:]]*server' "'\([^']*\)';")
    log_debug "Upload server $SERVER"

    FORM_HTML=$(grep_form_by_id "$PAGE" 'upload_form') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'uploadId') || return

    if [ -n "$PRIVATE_FILE" ]; then
        FORM_DATA_PRIV='--form-string private=checkbox'
        log_debug 'set as private file (as requested)'
    fi

    # Upload progress: we don't need this!
    # PAGE=$(curl -v "$BASE_URL/services/GetNewData?uploadId=$FORM_UID&server=$SERVER") || return

    PAGE=$(curl_with_log -F "uploadId=$FORM_UID" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        --form-string 'x=51' --form-string 'y=20' $FORM_DATA_PRIV \
        "$FORM_ACTION") || return

    # Take first occurrence
    FILE_URL=$(echo "$PAGE" | parse '="file_upload_remote"' '^\(.*\)$' 1) || return

    echo "$FILE_URL"
}
