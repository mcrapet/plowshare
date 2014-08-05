# Plowshare rghost.net module
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

MODULE_RGHOST_REGEXP_URL='https\?://\(www\.\)\?rghost\.net/'

MODULE_RGHOST_DOWNLOAD_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_RGHOST_DOWNLOAD_RESUME=no
MODULE_RGHOST_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_RGHOST_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_RGHOST_UPLOAD_OPTIONS="
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files
PRIVATE_FILE,,private,,Do not allow others to download the file"
MODULE_RGHOST_UPLOAD_REMOTE_SUPPORT=no

MODULE_RGHOST_PROBE_OPTIONS=""

# Output a rghost file download URL
# $1: cookie file (unused here)
# $2: rghost url
# stdout: real file download link
rghost_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2

    local PAGE FILE_URL FILE_NAME FILE_URL2

    PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return

    if match '<title>404 . page not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # Check for private link
    if match 'because the file is marked as private and the key' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FILE_NAME=$(parse_tag '/download/' a <<< "$PAGE")

    if match '[[:space:]]id=.form_for_password' "$PAGE"; then
        local FORM_HTML FORM_URL FORM_TOKEN
        local -r BASE_URL='http://rghost.net'

        log_debug 'File is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        FORM_HTML=$(grep_form_by_id "$PAGE" 'form_for_password' | \
            break_html_lines_alt) || return
        FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
        FORM_TOKEN=$(echo "$FORM_HTML" | parse_form_input_by_name 'authenticity_token') || return

        log_debug "authenticity token: '$FORM_TOKEN'"

        # Notes:
        # - mandatory: Accept header
        # - not required: -H 'X-Requested-With: XMLHttpRequest'
        PAGE=$(curl -v -b "$COOKIE_FILE" -e "$URL" \
            -H 'Accept: */*;q=0.5, text/javascript' \
            -H "X-CSRF-Token: $FORM_TOKEN" \
            -d 'utf8=%E2%9C%93' \
            -d "authenticity_token=$(uri_encode_strict <<< "$FORM_TOKEN")" \
            -d "password=$(uri_encode_strict <<< "$LINK_PASSWORD")" \
            -d 'commit=Get+link' \
            "$BASE_URL$FORM_URL") || return

        if ! match 'replaceWith(' "$PAGE"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        fi

        FILE_URL="$BASE_URL"$(parse '/download/' 'href=\\"\([^\\]\+\)\\"' <<< "$PAGE") || return
    else
        FILE_URL=$(parse_attr '/download/' href <<< "$PAGE") || return
    fi

    # Can have redirection or direct attachment
    FILE_URL2=$(curl --include "$FILE_URL" | grep_http_header_location_quiet)
    if test "$FILE_URL2"; then
        echo "$FILE_URL2"
    else
        echo "$FILE_URL"
    fi

    echo "$FILE_NAME"
}

# Upload a file to rghost.net
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
rghost_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://rghost.net'
    local PAGE FORM_HTML FORM_URL FORM_UTF8 FORM_TOKEN LINK_DL

    local -r MAX_SIZE=52428800 # 50 MiB
    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Get cookie "_rghost_session"
    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$BASE_URL") || return

    FORM_HTML=$(grep_form_by_id "$PAGE" 'upload_form' | \
        break_html_lines_alt) || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_TOKEN=$(echo "$FORM_HTML" | parse_form_input_by_name 'authenticity_token') || return
    FORM_UTF8=$(echo -e "\xe2\x9c\x93")

    log_debug "authenticity token: '$FORM_TOKEN'"

    # Notes:
    # - changes behavior: -H 'X-Awesome-Uploader: is awesome'
    # - Origin header and cookie-jar are mandatory
    PAGE=$(curl_with_log -L -b "$COOKIE_FILE" -c "$COOKIE_FILE" -e "$BASE_URL/main" \
        -H "Origin: $BASE_URL" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H 'X-Awesome-Uploader: is awesome' \
        -F "utf8=$FORM_UTF8" \
        -F "file=@$FILE;filename=$DEST_FILE" \
        -F "authenticity_token=$FORM_TOKEN" \
        -F 'commit=Upload' \
        "$FORM_URL") || return

    if match '>405 Not Allowed</' "$PAGE"; then
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    LINK_DL=$(parse . "=[[:space:]]*'\([^']\+\)" <<< "$PAGE") || return

    # Sanity check
    if [ "$LINK_DL" = "$BASE_URL" ]; then
        log_error 'remote server busy'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    if [ -n "$LINK_PASSWORD" -o -n "$DESCRIPTION" -o -n "$PRIVATE_FILE" ]; then
        log_debug 'Set file attributes'
        PAGE=$(curl -b "$COOKIE_FILE" -e "$LINK_DL" \
            -d 'utf8=%E2%9C%93' -d '_method=put' \
            -d "authenticity_token=$(uri_encode_strict <<< "$FORM_TOKEN")" \
            -d "download_url=$(uri_encode_strict <<< "$LINK_DL")" \
            -d "fileset%5Btags%5D=" \
            -d "fileset%5Bremoval_code%5D=" \
            -d "fileset%5Blifespan%5D=30" \
            -d "fileset%5Bdescription%5D=$(uri_encode_strict <<< "$DESCRIPTION")" \
            -d "fileset%5Bpassword%5D=$(uri_encode_strict <<< "$LINK_PASSWORD")" \
            ${PRIVATE_FILE:+-d 'fileset%5Bpublic%5D=0'} \
            -d 'commit=Update' \
            "$LINK_DL") || return

        if [ -n "$PRIVATE_FILE" ]; then
            LINK_DL=$(parse_attr 'rghost' href <<< "$PAGE") || return
        fi

    fi

    echo "$LINK_DL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: rghost url
# $3: requested capability list
# stdout: 1 capability per line
rghost_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE LOCATION FILE_SIZE REQ_OUT HASH

    PAGE=$(curl "$URL") || return

    if match '<title>404 . page not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # Check for private link
    if match 'because the file is marked as private and the key' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    REQ_OUT=c

    # Parse file name from download form action
    if [[ $REQ_IN = *f* ]]; then
        parse_tag '/download/' a <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '^<small' '^(\([^)]\+\)' 1 <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    # Provides both MD5 & SHA1
    if [[ $REQ_IN = *h* ]]; then
        HASH=$(parse '<dt>SHA1</dt>' '<dd>\([^<]\+\)' 1 <<< "$PAGE") && \
            echo "$HASH" && REQ_OUT="${REQ_OUT}h"
    fi

    echo $REQ_OUT
}
