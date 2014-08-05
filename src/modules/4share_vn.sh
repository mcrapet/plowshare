# Plowshare 4share.vn module
# Copyright (c) 2013 Plowshare team
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

MODULE_4SHARE_VN_REGEXP_URL='http://up\.4share\.vn/\(d\|f\)/[[:alnum:]]\+'

MODULE_4SHARE_VN_DOWNLOAD_OPTIONS=""
MODULE_4SHARE_VN_DOWNLOAD_RESUME=no
MODULE_4SHARE_VN_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_4SHARE_VN_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_4SHARE_VN_UPLOAD_OPTIONS=""
MODULE_4SHARE_VN_UPLOAD_REMOTE_SUPPORT=no

MODULE_4SHARE_VN_LIST_OPTIONS=""
MODULE_4SHARE_VN_LIST_HAS_SUBFOLDERS=no

MODULE_4SHARE_VN_PROBE_OPTIONS=""

# Output a 4share.vn file download URL
# $1: cookie file
# $2: 4share.vn url
# stdout: real file download link
4share_vn_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://up.4share.vn'

    local PAGE WAIT_TIME TIME CAPTCHA_IMG FILE_URL FILENAME

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    if match 'FID Không hợp lệ!' "$PAGE" || \
        match 'Xin lỗi bạn, File đã bị xóa' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    if match 'Đợi .* nữa để Download!' "$PAGE"; then
        WAIT_TIME=$(parse 'Đợi <b>' 'Đợi <b>\([^<]\+\)' <<< "$PAGE") || return

        log_error 'Forced delay between downloads.'

        echo "$WAIT_TIME"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    WAIT_TIME=$(parse 'var counter=' 'var counter=\([0-9]\+\)' <<< "$PAGE") || return

    # If captcha solve will take too long
    TIME=$(date +%s)

    CAPTCHA_IMG=$(create_tempfile '.jpg') || return

    curl -b "$COOKIE_FILE" -o "$CAPTCHA_IMG" \
        "$BASE_URL/library/captcha1.html" || return

    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG") || return
    { read WORD; read ID; } <<<"$WI"
    rm -f "$CAPTCHA_IMG"

    TIME=$(($(date +%s) - $TIME))
    if [ $TIME -lt $WAIT_TIME ]; then
        WAIT_TIME=$((WAIT_TIME - $TIME))
        wait $WAIT_TIME || return
    fi

    PAGE=$(curl -i -b "$COOKIE_FILE" \
        -d "security_code=$WORD" \
        -d 'submit=DOWNLOAD FREE' \
        -d 's=' \
        "$URL") || return

    if match 'Bạn đã nhập sai Mã bảo vệ download' "$PAGE"; then
        log_error 'Wrong captcha.'
        captcha_nack $ID
        return $ERR_CAPTCHA
    fi

    FILE_URL=$(grep_http_header_location <<< "$PAGE") || return
    FILENAME=$(parse . '&f=\([^&]\+\)' <<< "$FILE_URL") || return

    captcha_ack $ID

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to 4share.vn
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
4share_vn_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://4share.vn'

    local PAGE MAX_SIZE LINK_DL ERROR

    MAX_SIZE=209715200 # 200 MiB

    FILE_SIZE=$(get_filesize "$FILE")
    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Does not count files uploaded to free account for some reason, so login dropped for a while

    PAGE=$(curl_with_log \
        -F "Filename=$DEST_FILE" \
        -F 'name=public_upload' \
        -F 'folder=/files' \
        -F "Filedata=@$FILE;filename=$DEST_FILE" \
        -F 'Upload=Submit Query' \
        "$BASE_URL/upload_script/uploadify1.lib") || return

    if match 'ERROR' "$PAGE"; then
        ERROR=$(parse 'ERROR:\([^<]\+\)' <<< "$PAGE") || return
        log_error "Remote error: $ERROR"
        return $ERR_FATAL
    fi

    LINK_DL=$(parse_attr 'href' <<< "$PAGE") || return

    echo "$LINK_DL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: 4share.vn url
# $3: requested capability list
# stdout: 1 capability per line
4share_vn_probe() {
    local -r URL=$2
    local -r REQ_IN=$3

    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl "$URL") || return

    if match 'FID Không hợp lệ!' "$PAGE" || \
        match 'Xin lỗi bạn, File đã bị xóa' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse 'Downloading: <strong>' \
        'Downloading: <strong>\([^<]\+\)' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'c: <strong>' \
        'Kích thước: <strong>\([^<]\+\)' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a 4share.vn web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
4share_vn_list() {
    local -r URL=$1
    local -r REC=$2

    local PAGE URL_LIST LINKS NAMES

    URL_LIST=$(replace '/d/' '/dlist/' <<< "$URL")

    PAGE=$(curl "$URL_LIST") || return
    PAGE=$(break_html_lines_alt <<< "$PAGE")

    LINKS=$(parse_all_quiet '^http://up.4share.vn/f/' '^\([^<]\+\)' <<< "$PAGE")
    NAMES=$(parse_all_quiet '^http://up.4share.vn/f/' '^http://up.4share.vn/f/[[:alnum:]]\+/\([^<]\+\)' <<< "$PAGE")

    list_submit "$LINKS" "$NAMES"
}
