# Plowshare nowdownload.co module
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

MODULE_NOWDOWNLOAD_CO_REGEXP_URL='https\?://\(www\.\)\?nowdownload\.\(co\|ch\|eu\|sx\)/'

MODULE_NOWDOWNLOAD_CO_DOWNLOAD_OPTIONS=""
MODULE_NOWDOWNLOAD_CO_DOWNLOAD_RESUME=yes
MODULE_NOWDOWNLOAD_CO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_NOWDOWNLOAD_CO_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_NOWDOWNLOAD_CO_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_NOWDOWNLOAD_CO_UPLOAD_REMOTE_SUPPORT=yes

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
nowdownload_co_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE STATUS USER

    LOGIN_DATA='user=$USER&pass=$PASSWORD'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
       "$BASE_URL/login.php" -b "$COOKIE_FILE" \
       --location --referer "$BASE_URL/login.php") || return

    # Set-Cookie: user= & pass=
    STATUS=$(parse_cookie_quiet 'pass' < "$COOKIE_FILE")
    if [ -z "$STATUS" -o "$STATUS" = 'deleted' ]; then
        return $ERR_LOGIN_FAILED
    fi

    split_auth "$AUTH" USER || return
    log_debug "Successfully logged in as member '$USER'"

    echo "$PAGE"
}

# Output a nowdownload.co file download URL
# $1: cookie file
# $2: nowdownload.co url
# stdout: real file download link
nowdownload_co_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL=$(basename_url "$URL")
    local PAGE JS JS2 PART1 PART2 WAIT_TIME

    PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return

    if match '<div id="counter_container">' "$PAGE"; then
        detect_javascript || return

        JS=$(grep_script_by_order "$PAGE" 6) || return
        JS=$(echo "$JS" | delete_first_line | delete_last_line)
        JS2=$(echo 'function $(s) { print(s); };'"$JS" | javascript) || return

        # Do the parsing first
        PART1=$(parse '/api/token' '("\([^"]\+\)' <<< "$JS2") || return
        log_debug "token: '$PART1'"

        WAIT_TIME=$(parse 'var[[:space:]]\+ll' '=[[:space:]]*\([[:digit:]]\+\)' <<< "$JS2")
        PART2=$(parse 'Download your file' 'href=\\"\([^"]\+\)' <<< "$JS2") || return
        PART2=${PART2%\\}

        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL$PART1") || return
        wait $WAIT_TIME || return

        FILE_URL="$BASE_URL$PART2"
        # Bug???: You need Premium Membership to download this file.

    else
        FILE_URL=$(parse_attr 'icon-download' href <<< "$PAGE") || return
    fi

    echo $FILE_URL
}

# Upload a file to nowdownload.co
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: nowdownload.co download link
nowdownload_co_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://www.nowdownload.co'
    local -r MAX_SIZE=2147483648 # 2 GiB
    local PAGE UPLOAD_BASE_URL FORM_HTML FORM_DOMAIN GET_PATH UPLOAD_PATH UPLOAD_ID
    local TYPE

    if [ -n "$AUTH" ]; then
        PAGE=$(nowdownload_co_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
        UPLOAD_BASE_URL=$(parse_attr iframe src <<< "$PAGE") || return

        # Premium user ?
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/premium.php") || return

        if match 'You are a premium user. Your membership expires on' "$PAGE"; then
            log_debug 'premium user'
            TYPE=premium
        else
            TYPE=free
        fi
    else
        UPLOAD_BASE_URL='/upload.php'
    fi

    # Remote upload
    if match_remote_url "$FILE"; then
        if [ -z "$TYPE" ]; then
            log_error 'Remote upload requires an account'
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "remote_upload=$FILE" \
            -d "title=$DESTFILE" \
           "$BASE_URL/panel.php?q=4") || return

        UPLOAD_ID=$(parse_tag '>PROCESSING<' td <<< "$PAGE")
        log_debug "remote upload id: '$UPLOAD_ID'"
        return $ERR_ASYNC_REQUEST
    fi

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "File is bigger than $MAX_SIZE."
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # UberUpload engine
    # Set-Cookie: user=
    PAGE=$(curl -i -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        "$BASE_URL$UPLOAD_BASE_URL") || return

    # <h2><span>ERORR:</span> The upload limit has been reached!<br>
    if match 'The upload limit has been reached!<' "$PAGE"; then
        log_error 'Limit reached: 20 files per 24h'
        echo 43200
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    UPLOAD_BASE_URL=$(grep_http_header_location <<< "$PAGE") || return

    GET_PATH=$(parse 'UberUpload.path_to_link_script' \
        '=[[:space:]]*"\([^"]\+\)' <<< "$PAGE") || return

    FORM_HTML=$(grep_form_by_name "$PAGE" 'ubr_upload_form') || return
    FORM_DOMAIN=$(parse_form_input_by_name 'domain' <<< "$FORM_HTML") || return

    UPLOAD_PATH=$(parse 'UberUpload.path_to_upload_script' \
        '=[[:space:]]*"\([^"]\+\)' <<< "$PAGE") || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "domain=$FORM_DOMAIN" \
        -d "upload_file[]=$DESTFILE" \
        "${UPLOAD_BASE_URL%/*}/$GET_PATH") || return

    UPLOAD_ID=$(parse 'startUpload(' 'd("\([^"]\+\)' <<< "$PAGE") || return
    log_debug "upload id: '$UPLOAD_ID'"

    UPLOAD_BASE_URL=$(basename_url "$UPLOAD_BASE_URL") || return
    log_debug "upload base URL: '$UPLOAD_BASE_URL'"

    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -F "domain=$FORM_DOMAIN" \
        -F "upfile_$(date +%s)000=@$FILE;filename=$DESTFILE" \
        "$UPLOAD_BASE_URL$UPLOAD_PATH?upload_id=$UPLOAD_ID") || return

    UPLOAD_PATH=$(parse 'redirectAfterUpload(' "d('\([^']\+\)" <<< "$PAGE") || return

    PAGE=$(curl -b "$COOKIE_FILE" "$UPLOAD_BASE_URL$UPLOAD_PATH") || return

    parse_tag '/dl/' span <<< "$PAGE" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: nowdownload.co url
# $3: requested capability list
# stdout: 1 capability per line
nowdownload_co_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_NAME REQ_OUT

    PAGE=$(curl "$URL") || return

    # <p class="alert alert-danger">This file does not exist!</p>
    if match '>This file does not exist!<' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # <p class="alert alert-danger">The file is being transfered. Please wait!</p>
    if match '>The file is being transfered. Please wait!<' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse 'alert-success"' '^.*>[[:space:]]\?\([^<[:space:]]\+\)' <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    echo $REQ_OUT
}
