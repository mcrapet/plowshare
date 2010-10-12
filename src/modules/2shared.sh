#!/bin/bash
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

MODULE_2SHARED_REGEXP_URL="http://\(www\.\)\?2shared\.com/\(file\|document\|fadmin\|video\)/"
MODULE_2SHARED_DOWNLOAD_OPTIONS=""
MODULE_2SHARED_UPLOAD_OPTIONS=
MODULE_2SHARED_DELETE_OPTIONS=
MODULE_2SHARED_DOWNLOAD_CONTINUE=yes

# Output a 2shared file download URL
#
# $1: A 2shared URL
#
2shared_download() {
    eval "$(process_options 2shared "$MODULE_2SHARED_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    PAGE=$(curl "$URL") || return 1
    match "file link that you requested is not valid" "$PAGE" && return 254

    WS_OFUSCATED_URL=$(echo "$PAGE" |
        parse 'pageDownload' "'\/\(pageDownload1\/[^']*\)'") || return 1
    test "$CHECK_LINK" && return 255

    detect_javascript >/dev/null || return 1

    # JS offuscation code obtained by diffing the 2shared's tampered
    # jquery-1.3.2.min.js with the original one.
    WS_URL=$(echo "
        M = {url: '$WS_OFUSCATED_URL'};
        if (M.url != null && M.url.indexOf('eveLi') < M.url.indexOf('jsp?id') > 0) {
            var l2surl = M.url.substring(M.url.length - 32, M.url.length);
            if (l2surl.charCodeAt(0) % 2 == 1) {
                l2surl = l2surl.charAt(0) + l2surl.substr(17, l2surl.length);
            } else {
                l2surl = l2surl.substr(0, 15) + l2surl.charAt(l2surl.length - 1);
            }
            M.url = M.url.substring(0, M.url.indexOf(\"id=\") + 3) + l2surl;
        }
        print(M.url);
    " | javascript) || { log_error "error parsing ofuscated JS code"; return 1; }

    FILE_URL=$(curl "http://www.2shared.com/$WS_URL") || return 1
    FILENAME=$(echo "$PAGE" | grep -A1 '<div class="header">' |
        parse "Download" 'Download[[:space:]]*\([^<]\+\)' 2>/dev/null) || true

    echo "$FILE_URL"
    test "$FILENAME" && echo "$FILENAME"
}

# Upload a file to 2shared and upload URL (ADMIN_URL)
#
# 2shared_upload FILE [DESTFILE]
#
2shared_upload() {
    set -e
    eval "$(process_options 2shared "$MODULE_2SHARED_UPLOAD_OPTIONS" "$@")"
    local FILE=$1
    local DESTFILE=${2:-$FILE}
    local UPLOADURL="http://www.2shared.com/"

    log_debug "downloading upload page: $UPLOADURL"
    DATA=$(curl "$UPLOADURL")
    ACTION=$(grep_form_by_name "$DATA" "uploadForm" | parse_form_action) ||
        { log_debug "cannot get upload form URL"; return 1; }
    COMPLETE=$(echo "$DATA" | parse "uploadComplete" 'location="\([^"]*\)"')

    log_debug "starting file upload: $FILE"
    STATUS=$(curl_with_log \
        -F "mainDC=1" \
        -F "fff=@$FILE;filename=$(basename "$DESTFILE")" \
        "$ACTION")
    match "upload has successfully completed" "$STATUS" ||
        { log_error "upload failure"; return 1; }
    DONE=$(curl "$UPLOADURL/$COMPLETE")
    URL=$(echo "$DONE" | parse 'name="downloadLink"' "\(http:[^<]*\)")
    ADMIN=$(echo "$DONE" | parse 'name="adminLink"' "\(http:[^<]*\)")
    echo "$URL ($ADMIN)"
}

# Delete a file uploaded to 2shared
# $1: ADMIN_URL
2shared_delete() {
    eval "$(process_options 2shared "$MODULE_2SHARED_DELETE_OPTIONS" "$@")"

    BASE_URL="http://www.2shared.com"
    URL="$1"

    # Without cookie, it does not work
    COOKIES=$(create_tempfile)
    ADMIN_PAGE=$(curl -c $COOKIES "$URL")

    if ! match 'Delete File' "$ADMIN_PAGE"; then
        log_error "File not found"
        rm -f $COOKIES
        return 254
    else
        FORM=$(grep_form_by_name "$ADMIN_PAGE" 'theForm') || {
            log_error "can't get delete form, website updated?";
            rm -f $COOKIES
            return 1;
        }

        ACTION=$(echo "$FORM" | parse_form_action)
        DL_LINK=$(echo "$FORM" | parse_form_input_by_name 'downloadLink' | uri_encode_strict)
        AD_LINK=$(echo "$FORM" | parse_form_input_by_name 'adminLink' | uri_encode_strict)

        curl -b $COOKIES --referer "$URL" \
            --data "resultMode=2&password=&description=&publisher=&downloadLink=${DL_LINK}&adminLink=${AD_LINK}" \
            "$BASE_URL$ACTION" >/dev/null
        # Can't parse for success, we get redirected to main page

        rm -f $COOKIES
    fi
}
