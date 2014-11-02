# Plowshare thefilebay.com module
# Copyright (c) 2014 Plowshare team
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

MODULE_THEFILEBAY_REGEXP_URL='https\?://\(www\.\)\?thefilebay\.com/'

MODULE_THEFILEBAY_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_THEFILEBAY_DOWNLOAD_RESUME=yes
MODULE_THEFILEBAY_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_THEFILEBAY_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=
MODULE_THEFILEBAY_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_THEFILEBAY_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_THEFILEBAY_UPLOAD_REMOTE_SUPPORT=no

MODULE_THEFILEBAY_PROBE_OPTIONS=""

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
thefilebay_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT STATUS ERR

    LOGIN_DATA='username=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/ajax/_account_login.ajax.php") || return

    # filehosting cookie entry is added

    # {"error":"","login_status":"success","redirect_url":"https:\/\/thefilebay.com\/account_home.html"}
    # {"error":"Your username and password are invalid","login_status":"invalid"}
    STATUS=$(parse_json_quiet 'login_status' <<< "$LOGIN_RESULT")

    if [ "$STATUS" != 'success' ]; then
        ERR=$(parse_json 'error' <<< "$LOGIN_RESULT")
        log_debug "remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi
}

# Output a thefilebay.com file download URL
# $1: cookie file
# $2: thefilebay.com url
# stdout: real file download link and name
thefilebay_download() {
    local -r COOKIEFILE=$1
    local -r URL=$2
    local -r BASE_URL='https://thefilebay.com'
    local PAGE WAIT_TIME FILE_URL

    if [ -n "$AUTH_FREE" ]; then
        thefilebay_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl --location -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    if [ -z "$PAGE" ]; then
        return $ERR_LINK_DEAD
    fi

    WAIT_TIME=$(parse 'var[[:space:]]\+seconds' '=[[:space:]]*\([^;]*\)' <<< "$PAGE")
    wait $((WAIT_TIME)) || return

    FILE_URL=$(parse_attr "'\.download-timer')\.html"  href <<< "$PAGE") || return

    PAGE=$(curl -i -b "$COOKIE_FILE" "$FILE_URL") || return
    grep_http_header_location_quiet <<< "$PAGE"
}

# Upload a file to thefilebay.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
thefilebay_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='https://thefilebay.com'
    local PAGE ERR DL_URL DEL_URL
    local POST_URL SESSID TRACKER

    if [ -n "$AUTH_FREE" ]; then
        thefilebay_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$BASE_URL") || return
    POST_URL=$(parse '[[:space:]]\+url:' "url:[[:space:]]*'\([^']*\)" <<< "$PAGE") || return

    # data.formData = {_sessionid: 'p5qq9hbjhqssdofkf7q6b3ue27', cTracker: '257a5ec7adcecfc5fd691621af6d22d9', maxChunkSize: maxChunkSize},
    SESSID=$(parse 'data\.formData[[:space:]]*=' "_sessionid:[[:space:]]*'\([^']*\)" <<< "$PAGE") || return
    TRACKER=$(parse 'data\.formData[[:space:]]*=' "cTracker:[[:space:]]*'\([^']*\)" <<< "$PAGE") || return

    log_debug "session id: '$SESSID'"
    log_debug "tracker: '$TRACKER'"

    # Get "filehosting" cookie entry for serverXXX.thefilebay.com domain
    #curl -X OPTIONS -c "$COOKIE_FILE" -b "$COOKIE_FILE" -o /dev/null "$POST_URL" || return

    # Should returns:
    # Content-Disposition: inline; filename="files.json"
    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -F "_sessionid=$SESSID" \
        -F "cTracker=$TRACKER" \
        -F 'maxChunkSize=100000000' \
        -F 'folderId=' \
        -F "files[]=@$FILE;filename=$DEST_FILE" \
        "$POST_URL") || return

     ERR=$(parse_json_quiet 'error' <<< "$PAGE")
     if [ -n "$ERR" -a "$ERR" != 'null' ]; then
         log_error "Remote error: $ERR"
         return $ERR_FATAL
     fi

     DL_URL=$(parse_json_quiet 'url' <<< "$PAGE")
     DEL_URL=$(parse_json_quiet 'delete_url' <<< "$PAGE")

     echo "$DL_URL"
     echo "$DEL_URL"
     return 0
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: thefilebay url
# $3: requested capability list
# stdout: 1 capability per line
thefilebay_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_NAME

    PAGE=$(curl --location "$URL") || return

    if [ -z "$PAGE" ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '>File Name:<' 'g>[[:space:]]*\([^<]*\)' <<< "$PAGE" | html_to_utf8 && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '>File Size:<' 'g>[[:space:]]*\(.*\)$' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
