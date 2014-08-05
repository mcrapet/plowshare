# Plowshare data.hu module
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

MODULE_DATA_HU_REGEXP_URL='http://\(www\.\)\?data.hu/'

MODULE_DATA_HU_DOWNLOAD_OPTIONS=""
MODULE_DATA_HU_DOWNLOAD_RESUME=yes
MODULE_DATA_HU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_DATA_HU_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_DATA_HU_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"

MODULE_DATA_HU_DELETE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
data_hu_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local RND LOGIN_DATA JSON ERR USER

    RND=$(random h 32) || return
    LOGIN_DATA="act=dologin&login_passfield=login_$RND&target=%2Findex.php&t=&id=&data=&url_for_login=%2Findex.php%3Fisl%3D1&need_redirect=1&username=\$USER&login_$RND=\$PASSWORD"
    JSON=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
       "$BASE_URL/login.php" -H 'X-Requested-With: XMLHttpRequest') || return

    ERR=$(echo "$JSON" | parse_json 'error') || return

    if [ "$ERR" != 0 ]; then
        ERR=$(echo "$JSON" | parse_json 'message') || return
        match 'Sikeres bel\u00e9p\u00e9s!' "$ERR" && return $ERR_LOGIN_FAILED

        log_error "Remote error: $ERR"
        return $ERR_FATAL
    fi

    split_auth "$AUTH_FREE" USER || return
    log_debug "Successfully logged in as member '$USER'"
}

# Output a data_hu file download URL
# $1: cookie file
# $2: data.hu url
# stdout: real file download link
#         file name
data_hu_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://data.hu'
    local PAGE

    if [ -n "$AUTH_FREE" ]; then
        data_hu_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -L "$URL") || return

    match "/missing.php" "$PAGE" && return $ERR_LINK_DEAD

    # Extract + output download link and file name
    echo "$PAGE" | parse_attr 'download_box_button' 'href' || return
    echo "$PAGE" | parse_tag 'download_filename' 'div' || return
}

# Upload a file to Data.hu
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: data.hu download link
data_hu_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://data.hu'
    local PAGE UP_URL FORM SIZE MAX_SIZE MID SID

    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS
    data_hu_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/index.php?isl=1") || return
    UP_URL=$(echo "$PAGE" | \
        parse_attr '<iframe class="upload_frame_item"' 'src') || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL$UP_URL") || return
    FORM=$(grep_form_by_id "$PAGE" 'upload') || return

    MAX_SIZE=$(echo "$FORM" | parse_form_input_by_name 'MAX_FILE_SIZE') || return
    SIZE=$(get_filesize "$FILE") || return

    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    UP_URL=$(echo "$FORM" | parse_form_action) || return
    MID=$(echo "$FORM" | parse_form_input_by_id 'upload_target_mappaid') || return
    SID=$(echo "$UP_URL" | parse . 'sid=\([[:xdigit:]]\+\)$') || return

    curl_with_log -b "$COOKIE_FILE" \
        -F "MAX_FILE_SIZE=$MAX_SIZE" \
        -F "filedata=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        -F "upload_target_mappaid=$MID" \
        "$BASE_URL$UP_URL" -o /dev/null || return

    PAGE=$(curl -b "$COOKIE_FILE" --get -d 'upload=done' -d "sid=$SID" \
        "$BASE_URL/index.php") || return

    # Extract + output download link and delete link
    echo "$PAGE" | parse 'get_downloadlink_popup' \
        'downloadlink=\([^&]\+\)&filename' || return
    echo "$PAGE" | parse '?act=del&' '^[:blank:]*\(.\+\)$' || return
}

# Delete a file from Data.hu
# $1: cookie file (unused here)
# $2: data.eu (delete) link
data_hu_delete() {
    local -r URL=$2
    local PAGE

    PAGE=$(curl -L "$URL") || return

    # Note: Site redirects to JS redirect to main page if file does not exist
    match 'index.php?isl=1' "$PAGE" && return $ERR_LINK_DEAD

    # popup_message('Üzenet','A fájl (xyz 123KB) törlése sikerült!')
    match 'A fájl (.\+) törlése sikerült!' "$PAGE" && return 0

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}
