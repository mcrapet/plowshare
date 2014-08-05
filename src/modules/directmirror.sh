# Plowshare directmirror.com module
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

MODULE_DIRECTMIRROR_REGEXP_URL='https\?://\(www\.\)\?directmirror\.com/'

MODULE_DIRECTMIRROR_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
INCLUDE,,include,l=LIST,Provide list of host site (comma separated)
COUNT,,count,n=COUNT,Take COUNT mirrors (hosters) from the available list. Default is 2, maximum is 8 for anonymous and 18 for registered users."
MODULE_DIRECTMIRROR_UPLOAD_REMOTE_SUPPORT=no

MODULE_DIRECTMIRROR_LIST_OPTIONS=""
MODULE_DIRECTMIRROR_LIST_HAS_SUBFOLDERS=no

# Upload a file to directmirror.com
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: directmirror.com download link
directmirror_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.directmirror.com'
    local SITES_COUNT=0

    local PAGE FORM_HTML SITES_ALL SITES_SEL FORM_SITES_OPT SITE UPLOAD_RND UPLOAD_ID

    if [ -n "$COUNT" -a -n "$INCLUDE" ]; then
        log_error "Cannot use --count and --include at the same time."
        return $ERR_BAD_COMMAND_LINE
    fi

    [ -n "$COUNT" ] && SITES_COUNT="$COUNT"
    [ -n "$INCLUDE" ] && SITES_COUNT="${#INCLUDE[@]}"

    if [ "$SITES_COUNT" -gt 8 ] && [ -z "$AUTH" ]; then
        log_error "You must select 8 hosting sites or less. Register to increase the limit up to 18."
        return $ERR_BAD_COMMAND_LINE
    elif [ "$SITES_COUNT" -gt 18 ] && [ -n "$AUTH" ]; then
        log_error "You must select 18 hosting sites or less."
        return $ERR_BAD_COMMAND_LINE
    fi

    if [ -n "$AUTH" ]; then
        local LOGIN_DATA LOGIN_RESULT LOCATION

        LOGIN_DATA='username=$USER&password=$PASSWORD'
        LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/login.php?p=checklogin" -i) || return

        LOCATION=$(grep_http_header_location_quiet <<< "$LOGIN_RESULT")

        if ! match 'index.php' "$LOCATION"; then
            return $ERR_LOGIN_FAILED
        fi
    fi

    PAGE=$(curl "$BASE_URL" -b "$COOKIE_FILE") || return
    PAGE=$(break_html_lines <<< "$PAGE")

    FORM_HTML=$(grep_form_by_id "$PAGE" 'form_upload') || return
    SITES_ALL=$(parse_all_attr 'type="checkbox"' 'name' <<< "$FORM_HTML") || return

    if [ -n "$COUNT" ]; then
        for SITE in $SITES_ALL; do
            (( COUNT-- > 0 )) || break
            FORM_SITES_OPT=$FORM_SITES_OPT"-F $SITE=on "
        done
    elif [ "${#INCLUDE[@]}" -gt 0 ]; then
        for SITE in "${INCLUDE[@]}"; do
            if match "$SITE" "$SITES_ALL"; then
                FORM_SITES_OPT=$FORM_SITES_OPT"-F $SITE=on "
            else
                log_error "Host not supported: $SITE, ignoring"
            fi
        done
    else
        # Default hosting sites selection
        SITES_SEL=$(parse_all_attr 'checked="checked"' 'name' <<< "$FORM_HTML")
        for SITE in $SITES_SEL; do
            FORM_SITES_OPT=$FORM_SITES_OPT"-F $SITE=on "
        done
    fi

    if [ -z "$FORM_SITES_OPT" ]; then
        log_debug 'Empty site selection. Nowhere to upload!'
        return $ERR_FATAL
    fi

    UPLOAD_RND=$(random d 13)

    PAGE=$(curl -b "$COOKIE_FILE" \
        "$BASE_URL/ubr_link_upload_db.php?rnd_id=$UPLOAD_RND")

    UPLOAD_ID=$(parse 'startUpload' 'startUpload("\([^"]\+\)' <<< "$PAGE") || return

    PAGE=$(curl_with_log \
        -L \
        -b "$COOKIE_FILE" \
        -F 'upfile_desc=' \
        $FORM_SITES_OPT \
        -F "upfile_0=@$FILE;filename=$DEST_FILE" \
        "$BASE_URL/cgi/ubr_upload.pl?upload_id=$UPLOAD_ID") || return

    parse_tag 'Your download link is' 'a' <<< "$PAGE" || return

    return 0
}

# List links from a directmirror link
# $1: directmirror link
# $2: recurse subfolders (ignored here)
# stdout: list of links
directmirror_list() {
    local -r URL=$1
    local -r BASE_URL='http://www.directmirror.com'

    local PAGE SITE_URL LINKS REL_URL FILE_ID NAME SIZE

    FILE_ID=$(parse . '/files/\([a-zA-Z0-9]\+\)' <<< "$URL") || return

    PAGE=$(curl "$URL") || return
    NAME=$(parse_quiet 'File Name' '<b>\([^<]\+\)' 1 <<< "$PAGE")
    SIZE=$(parse_quiet 'File Size' '<b>\([^<]\+\)' 1 <<< "$PAGE")

    PAGE=$(curl -e "$URL" "$BASE_URL/status.php?uid=$FILE_ID") || return

    LINKS=$(parse_all_attr_quiet '/redirect/' href <<< "$PAGE")
    if [ -z "$LINKS" ]; then
        return $ERR_LINK_DEAD
    fi

    while read REL_URL; do
        test "$REL_URL" || continue

        PAGE=$(curl -e "$URL" "$BASE_URL$REL_URL") || return
        SITE_URL=$(parse_attr_quiet 'name="main"' 'src' <<< "$PAGE")

        # Some mirrors fail
        if [ -n "$SITE_URL" ]; then
            echo "$SITE_URL"
            echo "$NAME ($SIZE)"
        fi
    done <<< "$LINKS"
}
