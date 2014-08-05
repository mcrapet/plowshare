# Plowshare 2share.com module
# Copyright (c) 2010-2013 Plowshare team
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

MODULE_2SHARED_REGEXP_URL='http://\(www\.\)\?2shared\.com/\(file\|document\|fadmin\|photo\|audio\|video\)/'

MODULE_2SHARED_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account"
MODULE_2SHARED_DOWNLOAD_RESUME=yes
MODULE_2SHARED_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_2SHARED_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_2SHARED_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"
MODULE_2SHARED_UPLOAD_REMOTE_SUPPORT=no

MODULE_2SHARED_DELETE_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account"

MODULE_2SHARED_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
2shared_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3
    local LOGIN_DATA JSON_RESULT ERR

    LOGIN_DATA='login=$USER&password=$PASSWORD&callback=jsonp'
    JSON_RESULT=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
       "$BASE_URL/login") || return

    # {"ok":true,"rejectReason":"","loginRedirect":"http://...
    # Set-Cookie: Login Password
    if match_json_true 'ok' "$JSON_RESULT"; then
        return 0
    fi

    ERR=$(echo "$JSON_RESULT" | parse_json 'rejectReason')
    log_debug "Remote error: $ERR"
    return $ERR_LOGIN_FAILED
}

# Output a 2shared file download URL
# $1: cookie file (unused here)
# $2: 2shared url
# stdout: real file download link
2shared_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.2shared.com'
    local PAGE FILE_URL FILE_NAME WAIT_LINE WAIT_TIME

    # .htm are redirected to .html
    if [ -n "$AUTH_FREE" ]; then
        2shared_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
        PAGE=$(curl -L -b "$COOKIE_FILE" "$URL") || return
    else
        PAGE=$(curl -L "$URL") || return
    fi

    if match 'file link that you requested is not valid' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # We are sorry, but your download request can not be processed right now.
    if match 'id="timeToWait"' "$PAGE"; then
        WAIT_LINE=$(echo "$PAGE" | parse_tag 'timeToWait' span)
        WAIT_TIME=${WAIT_LINE%% *}
        if match 'minute' "$WAIT_LINE"; then
            echo $(( WAIT_TIME * 60 ))
        else
            echo $((WAIT_TIME))
        fi
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match '/photo/' "$URL"; then
        FILE_URL=$(echo "$PAGE" | parse 'retrieveLink\.jsp' "get('\([^']*\)")
        FILE_URL=$(curl "$BASE_URL$FILE_URL") || return

    else
        FILE_URL=$(parse_form_input_by_name 'd3link' <<< "$PAGE") || return
    fi


    FILE_NAME=$(echo "$PAGE" | parse_tag title | parse . '^\(.*\) download - 2shared$')

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to 2shared.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: 2shared.com download + admin link
2shared_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://www.2shared.com'

    local PAGE FORM_HTML FORM_ACTION FORM_DC COMPLETE DL_URL AD_URL

    test "$AUTH_FREE" || return $ERR_LINK_NEED_PERMISSIONS

    2shared_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return
    COMPLETE=$(echo "$PAGE" | parse 'uploadComplete' 'location="\([^"]*\)"')

    FORM_HTML=$(grep_form_by_name "$PAGE" 'uploadForm') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_DC=$(echo "$FORM_HTML" | parse_form_input_by_name 'mainDC') || return

    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -F "mainDC=$FORM_DC" -F 'x=0' -F 'y=0' \
        -F "fff=@$FILE;filename=$DESTFILE" \
        "$FORM_ACTION") || return

    # Your upload has successfully completed!
    if ! match 'upload has successfully completed' "$PAGE"; then
        log_error 'upload failure'
        return $ERR_FATAL
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL$COMPLETE") || return
    DL_URL=$(echo "$PAGE" | parse_attr '/\(file\|document\|photo\|audio\|video\)/' action) || return
    AD_URL=$(echo "$PAGE" | parse_attr '/fadmin/' action)

    echo "$DL_URL"
    echo
    echo "$AD_URL"
}

# Delete a file uploaded on 2shared
# $1: cookie file
# $2: admin url
2shared_delete() {
    local COOKIE_FILE=$1
    local URL=$2
    local BASE_URL='http://www.2shared.com'
    local ADMIN_PAGE FORM DL_LINK AD_LINK

    if [ -n "$AUTH_FREE" ]; then
        2shared_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    # 2Shared bug (2012-06): deleted files stays in the list of "My files"

    ADMIN_PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    if ! match 'Delete File' "$ADMIN_PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM=$(grep_form_by_name "$ADMIN_PAGE" 'theForm') || return
    DL_LINK=$(echo "$FORM" | parse_form_input_by_name 'downloadLink' | uri_encode_strict)
    AD_LINK=$(echo "$FORM" | parse_form_input_by_name 'adminLink' | uri_encode_strict)

    curl -b "$COOKIE_FILE" --referer "$URL" -o /dev/null \
        -d "adminLink=$AD_LINK" \
        -d "downloadLink=$DL_LINK" \
        -d 'resultMode=2&password=&description=&publisher=' \
        "$URL" || return
    # Can't parse for success, we get redirected to main page
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: 2shared.com url
# $3: requested capability list
2shared_probe() {
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl --location "$URL") || return

    # The file link that you requested is not valid.
    if match 'file link that you requested is not valid' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$PAGE" | parse_tag h1 | html_to_utf8 && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse '>File size' \
            '^[[:blank:]]*\([[:digit:]]\+\(.[[:digit:]]\+\)\?[[:space:]][KMG]\?B\)' 1) &&
            translate_size "${FILE_SIZE/,/}" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse 'action=' '"/complete/\([^/]\+\)' <<< "$PAGE" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}
