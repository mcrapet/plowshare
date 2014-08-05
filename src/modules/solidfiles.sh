# Plowshare solidfiles.com module
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

MODULE_SOLIDFILES_REGEXP_URL='https\?://\(www\.\)\?solidfiles\.com/\(d\|folder\)/'

MODULE_SOLIDFILES_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (used to download private files)"
MODULE_SOLIDFILES_DOWNLOAD_RESUME=yes
MODULE_SOLIDFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_SOLIDFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_SOLIDFILES_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
FOLDER,,folder,s=FOLDER,Folder to upload files into
PRIVATE,,private,,Mark file for personal use only"
MODULE_SOLIDFILES_UPLOAD_REMOTE_SUPPORT=no

MODULE_SOLIDFILES_LIST_OPTIONS=""
MODULE_SOLIDFILES_LIST_HAS_SUBFOLDERS=yes

MODULE_SOLIDFILES_PROBE_OPTIONS=""

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
solidfiles_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local PAGE LOCATION CSRF_TOKEN LOGIN_DATA LOGIN_RESULT

    PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL/login/")

    CSRF_TOKEN=$(parse_form_input_by_name 'csrfmiddlewaretoken' <<< "$PAGE")

    LOGIN_DATA="csrfmiddlewaretoken=$CSRF_TOKEN&username=\$USER&password=\$PASSWORD&next="
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        -i \
        -b "$COOKIE_FILE" \
        "$BASE_URL/login/") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$LOGIN_RESULT")

    if [ "$LOCATION" != 'http://www.solidfiles.com/manage/' ]; then
        return $ERR_LOGIN_FAILED
    fi
}

# Check if specified folder name is valid.
# When multiple folders wear the same name, first one is taken.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base URL
# stdout: folder ID
solidfiles_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local PAGE FOLDERS CSRF_TOKEN FOLDER_ID

    PAGE=$(curl -b "$COOKIE_FILE" \
        "$BASE_URL/manage/tree/") || return
    PAGE=$(replace_all '<li' $'\n<li' <<< "$PAGE") || return

    FOLDERS=$(parse_all '<li' '</ins>\([^<]\+\)' <<< "$PAGE") || return

    if ! match "^$NAME$" "$FOLDERS"; then
        log_debug 'Creating folder.'

        CSRF_TOKEN=$(parse_cookie 'csrftoken' < "$COOKIE_FILE") || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "csrfmiddlewaretoken=$CSRF_TOKEN" \
            -d "name=$NAME" \
            -d 'parent_id=0' \
            "$BASE_URL/manage/create_folder/?confirm=true") || return

        if [ "$PAGE" != 'ok' ]; then
            log_error "Could not create folder."
            return $ERR_FATAL
        fi

        PAGE=$(curl -b "$COOKIE_FILE" \
            "$BASE_URL/manage/tree/") || return
        PAGE=$(replace_all '<li' $'\n<li' <<< "$PAGE") || return

        FOLDERS=$(parse_all '<li' '</ins>\([^<]\+\)' <<< "$PAGE") || return

        if ! match "^$NAME$" "$FOLDERS"; then
            log_error "Could not create folder."
            return $ERR_FATAL
        fi
    fi

    FOLDER_ID=$(parse "<li.*</ins>$NAME</a>" '/manage/\([^/]\+\)' <<< "$PAGE") || return

    log_debug "Folder ID: '$FOLDER_ID'"

    echo "$FOLDER_ID"
}

# Output a solidfiles.com file download URL
# $1: cookie file
# $2: solidfiles.com url
# stdout: real file download link
solidfiles_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='https://www.solidfiles.com'

    local PAGE FILE_URL

    if [ -n "$AUTH" ]; then
        solidfiles_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -L -b "$COOKIE_FILE" "$URL") || return

    if match 'Not found' "$PAGE"; then
        log_error 'File is missing or marked as private.'
        return $ERR_LINK_DEAD
    fi

    FILE_URL=$(parse_attr 'download-button' 'href' <<< "$PAGE") || return

    if [ "$FILE_URL" = 'None' ]; then
        return $ERR_LINK_DEAD
    fi

    echo "$FILE_URL"
}

# Upload a file to solidfiles.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
solidfiles_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='https://www.solidfiles.com'
    local -r MAX_SIZE=524288000 # 500 MiB
    local -r FILE_SIZE=$(get_filesize "$FILE")

    local PAGE FOLDER_ID FILE_CODE

    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif [ -n "$PRIVATE" ]; then
            log_error 'You must be registered to flag private files.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
        log_debug "File is bigger than $MAX_SIZE."
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$AUTH" ]; then
        local SPACE_TOTAL SPACE_USED

        solidfiles_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            "$BASE_URL/manage/status/0/") || return

        SPACE_TOTAL=$(parse_json 'total_storage' <<< "$PAGE") || return
        SPACE_USED=$(parse_json 'storage_usage' <<< "$PAGE") || return

        # Check space limit
        if (( ( "$SPACE_TOTAL" - "$SPACE_USED" ) < "$FILE_SIZE" )); then
            log_error 'Not enough space in account folder.'
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(solidfiles_check_folder "$FOLDER" "$COOKIE_FILE" "$BASE_URL") || return
    else
        FOLDER_ID="0"
    fi

    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -F "name=$DESTFILE" \
        -F "file=@$FILE;filename=$DESTFILE" \
        "$BASE_URL/upload/process/$FOLDER_ID/") || return

    if ! match '^[[:alnum:]]\{10\}$' "$PAGE" || [ "${#PAGE}" != 10 ]; then
        log_error 'Upload failed.'
        return $ERR_FATAL
    else
        FILE_CODE="$PAGE"
    fi

    # Set private flag
    if [ -n "$PRIVATE" ]; then
        local CSRF_TOKEN

        log_debug 'Setting private flag...'

        CSRF_TOKEN=$(parse_cookie 'csrftoken' < "$COOKIE_FILE") || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "csrfmiddlewaretoken=$CSRF_TOKEN" \
            "$BASE_URL/manage/file/$FILE_CODE/toggle_public/?confirm=true") || return

        [ "$PAGE" != 'ok' ] && \
            log_error 'Could not set private flag.'
    fi

    echo "http://www.solidfiles.com/d/$FILE_CODE/"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: solidfiles.com url
# $3: requested capability list
# stdout: 1 capability per line
solidfiles_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_URL FILE_SIZE REQ_OUT

    PAGE=$(curl -L "$URL") || return

    if match 'Not found' "$PAGE"; then
        log_error 'File is missing or marked as private.'
        return $ERR_LINK_DEAD
    fi

    FILE_URL=$(parse_attr 'download-button' 'href' <<< "$PAGE") || return

    if [ "$FILE_URL" = 'None' ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse 'software_filename' "'\([^']\+\)'" <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        parse 'software_filesize' '[[:space:]]\([[:digit:]]\+\)' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a solidfiles.com web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
solidfiles_list() {
    local -r URL=$1
    local -r REC=$2
    local -r BASE_URL='http://www.solidfiles.com'

    local PAGE LINKS NAMES

    PAGE=$(curl -L "$URL") || return

    if match 'Not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    LINKS=$(parse_all_attr_quiet '<a href="/d/' 'href' <<< "$PAGE")
    LINKS=$(replace '/d/' "$BASE_URL/d/" <<< "$LINKS")

    NAMES=$(parse_all_tag_quiet '<a href="/d/' 'a' <<< "$PAGE")

    list_submit "$LINKS" "$NAMES" && RET=0

    # Are there any subfolders?
    if [ -n "$REC" ]; then
        local FOLDERS FOLDER

        FOLDERS=$(parse_all_attr_quiet '<a href="/folder/' 'href' <<< "$PAGE") || return

        while read FOLDER; do
            [ -z "$FOLDER" ] && continue
            log_debug "Entering sub folder: $BASE_URL$FOLDER"
            solidfiles_list "$BASE_URL$FOLDER" "$REC" && RET=0
        done <<< "$FOLDERS"
    fi

    return $RET
}
