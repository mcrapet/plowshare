#!/bin/bash
#
# zshare.net module
# Copyright (c) 2010-2011 Plowshare team
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

MODULE_ZSHARE_REGEXP_URL="http://\(www\.\)\?zshare\.net/\(download\|delete\|audio\|video\)"

MODULE_ZSHARE_DOWNLOAD_OPTIONS=""
MODULE_ZSHARE_DOWNLOAD_RESUME=yes
MODULE_ZSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_ZSHARE_UPLOAD_OPTIONS="
DESCRIPTION,d:,description:,DESCRIPTION,Set file description"
MODULE_ZSHARE_DELETE_OPTIONS=""

# Output a zshare file download URL
# $1: cookie file
# $2: zshare.net url
# stdout: real file download link
zshare_download() {
    local COOKIEFILE="$1"
    local URL=$(echo "$2" | replace '/audio/' '/download/' | \
                            replace '/video/' '/download/')

    WAITPAGE=$(curl -L -c $COOKIEFILE --data "download=1" "$URL") || return
    match "File Not Found" "$WAITPAGE" &&
        { log_debug "file not found"; return $ERR_LINK_DEAD; }

    test "$CHECK_LINK" && return 0

    detect_javascript || return

    WAITTIME=$(echo "$WAITPAGE" | parse "document|important||here" \
        "||here|\([[:digit:]]\+\)")

    wait $((WAITTIME)) seconds || return

    JSCODE=$(echo "$WAITPAGE" | grep "var link_enc")

    FILE_URL=$(echo "$JSCODE" "; print(link);" | javascript)
    FILENAME=$(echo "$WAITPAGE" |\
        parse '<h2>[Dd]ownload:' '<h2>[Dd]ownload:[[:space:]]*\([^<]*\)')

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to zshare.net
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: zshare download + del link
zshare_upload() {
    eval "$(process_options zshare "$MODULE_ZSHARE_UPLOAD_OPTIONS" "$@")"

    local FILE="$2"
    local DESTFILE="$3"
    local UPLOADURL="http://www.zshare.net/"

    log_debug "downloading upload page: $UPLOADURL"
    DATA=$(curl "$UPLOADURL") || return

    ACTION=$(grep_form_by_name "$DATA" 'upload' | parse_form_action) ||
        { log_debug "cannot get upload form URL"; return 1; }

    log_debug "form action: $ACTION"
    log_debug "starting file upload: $FILE"

    # There is actually two methods for uploading one file.
    # The first drops the description field but has only one HTTP post request.
    # I'm keeping both, just in case.
    if [ -z "$DESCRIPTION" ]; then
        INFOPAGE=$(curl_with_log -L \
            -F "file=@$FILE;filename=$DESTFILE" \
            -F "descr=$DESCRIPTION" \
            -F "is_private=0"       \
            -F "TOS=1"              \
            -F "pass="              \
            "$ACTION")
    else
        DATA=$(curl "${ACTION}uberupload/ubr_link_upload.php?rnd_id=$RANDOM")
        ID=$(echo "$DATA" | parse 'startUpload(' 'd("\([^"]*\)')
        log_debug "id:$ID"

        # Escaped version
        DESCR=$(echo "$DESCRIPTION" | uri_encode_strict)

        # Note: description is taken from URL and not from form field
        INFOPAGE=$(curl_with_log -L \
            -F "file=@$FILE;filename=$DESTFILE" \
            -F "descr=$DESCRIPTION" \
            -F "is_private=0"       \
            -F "TOS=1"              \
            -F "pass="              \
            "${ACTION}cgi-bin/ubr_upload.pl?upload_id=${ID}&descr=$DESCR")
    fi

    match "was successfully uploaded" "$INFOPAGE" ||
        { log_error "upload unsuccessful"; return 1; }

    DOWNLOAD_URL=$(echo "$INFOPAGE" | parse_attr 'http:\/\/www\.zshare\.net\/\(download\|audio\|video\)' 'href') ||
        { log_debug "can't parse download link, website updated?"; return 1; }
    DELETE_URL=$(echo "$INFOPAGE" | parse_attr "http:\/\/www\.zshare\.net\/delete" 'value') ||
        { log_debug "can't parse delete link, website updated?"; return 1; }

    echo "$DOWNLOAD_URL ($DELETE_URL)"
}

# Delete a file from zshare
# $1: delete link
zshare_delete() {
    eval "$(process_options zshare "$MODULE_ZSHARE_DELETE_OPTIONS" "$@")"

    local URL="$1"
    local DELETE_PAGE FORM_KILLCODE RESULT_PAGE

    DELETE_PAGE=$(curl -L "$URL") || return

    if matchi 'File Not Found' "$DELETE_PAGE"; then
        log_error "File not found"
        return $ERR_LINK_DEAD
    else
        FORM_KILLCODE=$(echo "$DELETE_PAGE" | parse_form_input_by_name "killCode")
        RESULT_PAGE=$(curl --data "killCode=$FORM_KILLCODE" "$URL") || return

        if match 'Invalid removal code' "$RESULT_PAGE"; then
            log_error "bad removal code"
            return $ERR_FATAL
        elif ! matchi 'File Removed' "$RESULT_PAGE"; then
            log_error "unexpected result, file not deleted"
            return $ERR_FATAL
        fi
    fi
}
