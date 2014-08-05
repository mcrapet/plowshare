# Plowshare exoshare.com module
# Copyright (c) 2011-2014 Plowshare team
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

MODULE_EXOSHARE_REGEXP_URL='https\?://\(www\.\)\?\(exoshare\.com\|multi\.la\)/'

MODULE_EXOSHARE_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
INCLUDE,,include,l=LIST,Provide list of host site (comma separated)
SHORT_LINK,,short-link,,Produce short link like http://multi.la/s/XXXXXXXX
COUNT,,count,n=COUNT,Take COUNT mirrors (hosters) from the available list. Default is 12.
API,,api,,Use API to upload file
API_KEY,,api-key,s=API_KEY,Provide API key to use instead of login:pass. Can be used without --api option."
MODULE_EXOSHARE_UPLOAD_REMOTE_SUPPORT=yes

MODULE_EXOSHARE_LIST_OPTIONS=""
MODULE_EXOSHARE_LIST_HAS_SUBFOLDERS=no

# Upload a file to exoshare.com
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: exoshare.com download link
exoshare_upload() {
    if [ -n "$API" -o -n "$API_KEY" ]; then
        if [ -z "$AUTH" -a -z "$API_KEY" ]; then
            log_error 'API does not allow anonymous uploads.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        if [ -n "$AUTH" -a -n "$API_KEY" ]; then
            log_error 'Cannot use --api-key and --auth at the same time.'
            return $ERR_BAD_COMMAND_LINE
        fi

        if [ -n "$COUNT" -o -n "$INCLUDE" ]; then
            log_error 'API does not support --count and --include.'
            return $ERR_BAD_COMMAND_LINE
        fi

        if match_remote_url "$FILE"; then
            log_error 'API does not support remote upload.'
            return $ERR_BAD_COMMAND_LINE
        fi

        exoshare_upload_api "$@"
    else
        local SITES_COUNT

        if [ -n "$COUNT" -a -n "$INCLUDE" ]; then
            log_error 'Cannot use --count and --include at the same time.'
            return $ERR_BAD_COMMAND_LINE
        fi

        [ -n "$COUNT" ] && SITES_COUNT="$COUNT"
        [ -n "$INCLUDE" ] && SITES_COUNT="${#INCLUDE[@]}"

        if [ "$SITES_COUNT" -gt 12 ]; then
            log_error 'You must select 12 hosting sites or less.'
            return $ERR_BAD_COMMAND_LINE
        fi

        exoshare_upload_regular "$@"
    fi
}

# Upload a file to exoshare.com using official API
# http://exoshare.com/api.php
# $1: cookie file (not used here)
# $2: input file (with full path)
# $3: remote filename
# stdout: exoshare.com download link
exoshare_upload_api() {
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.exoshare.com'

    local PAGE FILE_LINK

    if [ -n "$API_KEY" ]; then
        PAGE=$(curl_with_log \
            -F "key=$API_KEY" \
            -F 'submit=Send' \
            -F "file_0=@$FILE;filename=$DEST_FILE" \
            "$BASE_URL/api/api.php") || return

        if match 'Wrong Key !' "$PAGE"; then
            log_error 'Wrong API key.'
            return $ERR_LOGIN_FAILED
        fi
    else
        local USER PASSWORD

        split_auth "$AUTH" USER PASSWORD || return

        PAGE=$(curl_with_log \
            -F "user=$USER" \
            -F "password=$PASSWORD" \
            -F "file_0=@$FILE;filename=$DEST_FILE" \
            "$BASE_URL/upload.php") || return

        if match 'Wrong Username/Password' "$PAGE"; then
            return $ERR_LOGIN_FAILED
        fi
    fi

    if ! match '^http://www\.exoshare\.com/download\.php?uid=[A-Z0-9]\+$' "$PAGE"; then
        log_error 'Upload failed'
        return $ERR_FATAL
    fi

    FILE_LINK="$PAGE"

    if [ -n "$SHORT_LINK" ]; then
        replace 'http://www.exoshare.com/download.php?uid=' 'http://multi.la/s/' <<< "$FILE_LINK"
    else
        echo "$FILE_LINK"
    fi
}

# Upload a file to exoshare.com using regular site
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: exoshare.com download link
exoshare_upload_regular() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.exoshare.com'
    local SITES_COUNT=0

    local PAGE FORM_HTML SITES_ALL SITES_SEL FORM_SITES_OPT SITE UPLOAD_RND UPLOAD_ID LINK_SCRIPT UPLOAD_SCRIPT

    if [ -n "$AUTH" ]; then
        local LOGIN_DATA LOGIN_RESULT LOCATION

        LOGIN_DATA='username=$USER&pass=$PASSWORD&submit='
        LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/login.php" -i) || return

        LOCATION=$(grep_http_header_location_quiet <<< "$LOGIN_RESULT")

        if ! match 'account.php' "$LOCATION"; then
            return $ERR_LOGIN_FAILED
        fi
    fi

    PAGE=$(curl "$BASE_URL" -b "$COOKIE_FILE") || return
    PAGE=$(break_html_lines <<< "$PAGE")

    FORM_HTML=$(grep_form_by_id "$PAGE" 'form_upload') || return
    SITES_ALL=$(parse_all_attr 'type="checkbox"' 'name' <<< "$FORM_HTML") || return

    LINK_SCRIPT=$(parse 'var path_to_link_script' ' = "\([^"]\+\)' <<< "$PAGE") || return
    UPLOAD_SCRIPT=$(parse 'var path_to_upload_script' ' = "\([^"]\+\)' <<< "$PAGE") || return

    if match_remote_url "$FILE"; then
        REMOTE_FLAG='remote'
    fi

    if [ -n "$COUNT" ]; then
        for SITE in $SITES_ALL; do
            (( COUNT-- > 0 )) || break
            FORM_SITES_OPT=$FORM_SITES_OPT"-F $SITE$REMOTE_FLAG=on "
        done
    elif [ "${#INCLUDE[@]}" -gt 0 ]; then
        for SITE in "${INCLUDE[@]}"; do
            if match "$SITE" "$SITES_ALL"; then
                FORM_SITES_OPT=$FORM_SITES_OPT"-F $SITE$REMOTE_FLAG=on "
            else
                log_error "Host not supported: $SITE, ignoring"
            fi
        done
    else
        # Default hosting sites selection
        SITES_SEL=$(parse_all_attr 'checked="checked"' 'name' <<< "$FORM_HTML")
        for SITE in $SITES_SEL; do
            FORM_SITES_OPT=$FORM_SITES_OPT"-F $SITE$REMOTE_FLAG=on "
        done
    fi

    if [ -z "$FORM_SITES_OPT" ]; then
        log_debug 'Empty site selection. Nowhere to upload!'
        return $ERR_FATAL
    fi

    UPLOAD_RND=$(random d 13)

    PAGE=$(curl -b "$COOKIE_FILE" \
        "$BASE_URL/$LINK_SCRIPT?rnd_id=$UPLOAD_RND")

    if match 'Error, registering for a free account is required.' "$PAGE"; then
        log_error 'Anonymous uploads limit exceeded.'
        return $ERR_FATAL
    fi

    UPLOAD_ID=$(parse 'startUpload' 'startUpload("\([^"]\+\)' <<< "$PAGE") || return

    if match_remote_url "$FILE"; then
        PAGE=$(curl_with_log \
            -b "$COOKIE_FILE" \
            -F "url=$FILE" \
            -F "newfname=$DEST_FILE" \
            $FORM_SITES_OPT \
            "$BASE_URL/remote.php") || return
    else
        PAGE=$(curl_with_log \
            -L \
            -b "$COOKIE_FILE" \
            -F 'mail=' \
            $FORM_SITES_OPT \
            -F "upfile_0=@$FILE;filename=$DEST_FILE" \
            "$BASE_URL$UPLOAD_SCRIPT?upload_id=$UPLOAD_ID") || return
    fi

    FILE_ID=$(parse 'Your download link is' '?uid=\([A-Z0-9]\+\)' <<< "$PAGE") || return

    if [ -n "$SHORT_LINK" ]; then
        echo "http://multi.la/s/$FILE_ID"
    else
        echo "http://exoshare.com/download.php?uid=$FILE_ID"
    fi

    return 0
}

# List links from a exoshare link
# $1: exoshare link
# $2: recurse subfolders (ignored here)
# stdout: list of links
exoshare_list() {
    local -r URL=$1
    local -r BASE_URL='http://www.exoshare.com'
    local PAGE SITE_URL LINKS REL_URL NAME SIZE FILE_ID

    if match 'multi.la' "$URL"; then
        FILE_ID=$(parse . '/s/\([a-zA-Z0-9]\+\)' <<< "$URL") || return
    else
        FILE_ID=$(parse . 'uid=\([a-zA-Z0-9]\+\)' <<< "$URL") || return
    fi

    PAGE=$(curl "$URL") || return
    NAME=$(parse_quiet 'Name : ' 'Name : \([^<]\+\)' <<< "$PAGE")
    SIZE=$(parse_quiet 'Size : ' 'Size : \([^<]\+\)' <<< "$PAGE")

    PAGE=$(curl -e "$BASE_URL/download.php?uid=$FILE_ID" "$BASE_URL/status.php?uid=$FILE_ID") || return

    LINKS=$(parse_all_attr_quiet '/redirect.php' href <<< "$PAGE")
    if [ -z "$LINKS" ]; then
        return $ERR_LINK_DEAD
    fi

    while read REL_URL; do
        test "$REL_URL" || continue

        PAGE=$(curl -i -e "$BASE_URL/download.php?uid=$FILE_ID" "$BASE_URL$REL_URL") || return
        LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

        # Some mirrors fail
        if [ -n "$LOCATION" ]; then
            echo "$LOCATION"
            echo "$NAME ($SIZE)"
        fi
    done <<< "$LINKS"
}
