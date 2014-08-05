# Plowshare mirrorupload.net module
# Copyright (c) 2011-2013 Plowshare team
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

MODULE_MIRRORUPLOAD_REGEXP_URL='https\?://\(www\.\)\?mirrorupload\.net/'

MODULE_MIRRORUPLOAD_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
INCLUDE,,include,l=LIST,Provide list of host site (comma separated)
API,,api,,Use API to upload file"
MODULE_MIRRORUPLOAD_UPLOAD_REMOTE_SUPPORT=no

MODULE_MIRRORUPLOAD_LIST_OPTIONS=""
MODULE_MIRRORUPLOAD_LIST_HAS_SUBFOLDERS=no

# Upload a file to mirrorupload.net
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: mirrorupload.net download link
mirrorupload_upload() {
    if [ -n "$API" ]; then
        if [ -z "$AUTH" ]; then
            log_error 'API does not allow anonymous uploads.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        if [ -n "$INCLUDE" ]; then
            log_error 'API does not support --include option.'
            return $ERR_BAD_COMMAND_LINE
        fi

        mirrorupload_upload_api "$@"
    else
        if [ "${#INCLUDE[@]}" -gt 12 ]; then
            log_error "You must select 12 hosting sites or less."
            return $ERR_BAD_COMMAND_LINE
        fi

        mirrorupload_upload_regular "$@"
    fi
}

# Upload a file to mirrorupload.net using official API
# http://www.mirrorupload.net/api.html
# $1: cookie file (not used here)
# $2: input file (with full path)
# $3: remote filename
# stdout: mirrorupload.net download link
mirrorupload_upload_api() {
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.mirrorupload.net'

    local PAGE RESULT REPLY UPLOAD_URL SESSION_ID USER PASSWORD

    PAGE=$(curl "$BASE_URL/api/server.html") || return

    RESULT=$(parse_json 'result' <<< "$PAGE") || return
    REPLY=$(parse_json 'reply' <<< "$PAGE") || return

    if [ "$RESULT" != 'ok' ]; then
        log_error "Remote error: $REPLY"
        return $ERR_FATAL
    fi

    UPLOAD_URL="$REPLY"

    split_auth "$AUTH" USER PASSWORD || return

    PAGE=$(curl \
        -d "login=$USER" \
        -d "pass=$PASSWORD" \
        "$BASE_URL/api/member.html") || return

    RESULT=$(parse_json 'result' <<< "$PAGE") || return
    REPLY=$(parse_json 'reply' <<< "$PAGE") || return

    if [ "$RESULT" != 'ok' ]; then
        log_error "Remote error: $REPLY"
        return $ERR_LOGIN_FAILED
    fi

    SESSION_ID="$REPLY"

    PAGE=$(curl_with_log \
        -F "session_id=$SESSION_ID" \
        -F "file=@$FILE;filename=$DEST_FILE" \
        "$UPLOAD_URL") || return

    RESULT=$(parse_json 'result' <<< "$PAGE") || return
    REPLY=$(parse_json 'reply' <<< "$PAGE") || return

    if [ "$RESULT" != 'ok' ]; then
        log_error "Remote error: $REPLY"
        return $ERR_FATAL
    fi

    echo "$REPLY"
}

# Upload a file to mirrorupload.net using regular form upload
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: mirrorupload.net download link
mirrorupload_upload_regular() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.mirrorupload.net'

    local PAGE

    if [ -n "$AUTH" ]; then
        local LOGIN_DATA LOGIN_RESULT LOCATION

        LOGIN_DATA='login=$USER&pass=$PASSWORD'
        LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/index.html" -i) || return

        LOCATION=$(grep_http_header_location_quiet <<< "$LOGIN_RESULT")

        if ! match 'account.html' "$LOCATION"; then
            return $ERR_LOGIN_FAILED
        fi
    fi

    PAGE=$(curl "$BASE_URL" -b "$COOKIE_FILE") || return

    local FORM_HTML FORM_ACTION FORM_UPLOAD_ID FORM_LOGIN_ID FORM_SITES FORM_SITES_OPT SITE
    FORM_HTML=$(grep_form_by_id "$PAGE" 'fileupload') || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_UPLOAD_ID=$(parse_form_input_by_name 'upload_id' <<< "$FORM_HTML") || return
    FORM_LOGIN_ID=$(parse_form_input_by_name_quiet 'idlogin' <<< "$FORM_HTML")

    if [ "${#INCLUDE[@]}" -gt 0 ]; then
        for SITE in "${INCLUDE[@]}"; do
            FORM_SITES_OPT=$FORM_SITES_OPT"-F $SITE=on "
        done
    else
        FORM_SITES=$(parse_all_attr 'type="checkbox"' 'name' <<< "$FORM_HTML") || return

        while read SITE; do
            FORM_SITES_OPT=$FORM_SITES_OPT"-F $SITE=on "
        done <<< "$FORM_SITES"
    fi

    PAGE=$(curl_with_log \
        -F "upload_id=$FORM_UPLOAD_ID" \
        -F "idlogin=$FORM_LOGIN_ID" \
        $FORM_SITES_OPT \
        -F "files[]=@$FILE;filename=$DEST_FILE" \
        "$FORM_ACTION") || return

    parse_json 'url' <<< "$PAGE" || return

    return 0
}

# List links from a mirrorupload link
# $1: mirrorupload link
# $2: recurse subfolders (ignored here)
# stdout: list of links
mirrorupload_list() {
    local -r URL=$(replace '://mirrorupload.net' '://www.mirrorupload.net' <<< "$1")
    local -r BASE_URL='http://www.mirrorupload.net'

    local PAGE LINKS NAME REL_URL LOCATION

    PAGE=$(curl -d "access=Go to the download links" "$URL") || return
    PAGE=$(break_html_lines <<< "$PAGE")

    LINKS=$(parse_all_attr_quiet 'Download File' href <<< "$PAGE")
    if [ -z "$LINKS" ]; then
        return $ERR_LINK_DEAD
    fi

    NAME=$(parse_tag 'h1' <<< "$PAGE") || return

    # Remove direct-download link, premium only
    LINKS=$(delete_first_line <<< "$LINKS")

    while read REL_URL; do
        test "$REL_URL" || continue

        PAGE=$(curl -e "$URL" -i "$BASE_URL/$REL_URL") || return
        LOCATION=$(grep_http_header_location <<< "$PAGE") || return

        echo "$LOCATION"
        echo "$NAME"
    done <<< "$LINKS"
}
