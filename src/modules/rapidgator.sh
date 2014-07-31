#!/bin/bash
#
# rapidgator.net module
# Copyright (c) 2012-2014 Plowshare team
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

MODULE_RAPIDGATOR_REGEXP_URL='http://\(www\.\)\?rapidgator\.net/'

MODULE_RAPIDGATOR_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account"
MODULE_RAPIDGATOR_DOWNLOAD_RESUME=yes
MODULE_RAPIDGATOR_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_RAPIDGATOR_DOWNLOAD_SUCCESSIVE_INTERVAL=2100

MODULE_RAPIDGATOR_UPLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account
FOLDER,,folder,s=FOLDER,Folder to upload files into (account only)
ASYNC,,async,,Asynchronous remote upload (only start upload, don't wait for link)
CLEAR,,clear,,Clear list of remote uploads"
MODULE_RAPIDGATOR_UPLOAD_REMOTE_SUPPORT=yes

MODULE_RAPIDGATOR_LIST_OPTIONS=""
MODULE_RAPIDGATOR_LIST_HAS_SUBFOLDERS=no

MODULE_RAPIDGATOR_DELETE_OPTIONS=""
MODULE_RAPIDGATOR_PROBE_OPTIONS=""

# Static function. Proceed with login (free)
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
rapidgator_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=${3/#http/https}
    local LOGIN_DATA HTML EMAIL TYPE STATUS

    LOGIN_DATA='LoginForm[email]=$USER&LoginForm[password]=$PASSWORD&LoginForm[rememberMe]=1'
    HTML=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/auth/login" -L -b "$COOKIE_FILE") || return

    # Check for JS redirection
    # <script language="JavaScript">function ZD5wC ... window.location.href='/auth/login?'+MGOwqz+'';MGOwqz='';</script>
    if match 'window.location.href=' "$HTML"; then
        log_debug 'JS redirect detected'
        local JS_CODE REDIR

        detect_javascript || return
        JS_CODE=$(parse . '<script language="JavaScript">\(.\+\)</script>' <<< "$HTML") || return
        REDIR=$(javascript <<< "var window={};window.location={}; $JS_CODE print(window.location.href);") || return
        HTML=$(curl -L -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$BASE_URL$REDIR") || return
    fi

    STATUS=$(parse_cookie_quiet 'user__' < "$COOKIE_FILE")

    # Check for some heavy usage login problems
    if [ -z "$STATUS" ]; then
        # Forced wait
        # <li>Frequent logins. Please wait 20 sec...</li>
        if match 'Frequent logins' "$HTML"; then
            log_debug 'Login detention detected'
            local WAIT_TIME

            WAIT_TIME=$(parse 'Frequent logins' \
                'Please wait \([[:digit:]]\+\) sec' <<< "$HTML") || return
            wait $WAIT_TIME || return

            # Retry login
            HTML=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
                "$BASE_URL/auth/login" -L -b "$COOKIE_FILE") || return

        # CAPTCHA
        # <li>The code from a picture does not coincide</li>
        elif match 'The code from a picture does not coincide' "$HTML"; then
            log_debug 'Login CAPTCHA detected'
            local CAPTCHA_URL IMG_FILE WI WORD ID

            IMG_FILE=$(create_tempfile '.rapidgator.jpg') || return

            # Get captcha image
            CAPTCHA_URL=$(parse_attr 'auth/captcha' 'src' <<< "$HTML") || return
            curl -b "$COOKIE_FILE" -o "$IMG_FILE" "${BASE_URL}${CAPTCHA_URL}" || return

            # Solve captcha
            # Note: Image is a 120x50 png file containing 5 characters
            WI=$(captcha_process "$IMG_FILE" rapidgator 5 5) || return
            { read WORD; read ID; } <<< "$WI"
            rm -f "$IMG_FILE"

            # Retry login with CAPTCHA
            HTML=$(post_login "$AUTH" "$COOKIE_FILE" "${LOGIN_DATA}&LoginForm[verifyCode]=$WORD" \
            "$BASE_URL/auth/login" -L -b "$COOKIE_FILE") || return

            if match 'The code from a picture does not coincide' "$HTML"; then
                captcha_nack "$ID"
                return $ERR_CAPTCHA
            fi

            captcha_ack "$ID"
            STATUS=$(parse_cookie_quiet 'user__' < "$COOKIE_FILE")

        else
            local FORM=$(grep_form_by_id_quiet "$HTML" 'registration')
            log_debug "Unexpected login issue: $FORM"
            return $ERR_FATAL
        fi
    fi

    if [ -z "$STATUS" ]; then
        if match 'Error e-mail or password' "$HTML"; then
            return $ERR_LOGIN_FAILED
        fi

        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    split_auth "$AUTH" EMAIL || return

    if match '^[[:space:]]*Account:.*Free' "$HTML"; then
        TYPE='free'
    elif match "^[[:space:]]*Premium.*$EMAIL" "$HTML"; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi
    log_debug "Successfully logged in as $TYPE member '$EMAIL'"

    echo "$TYPE"
}

# Switch language to english
# $1: cookie file
# $2: base URL
rapidgator_switch_lang() {
    curl -b "$1" -c "$1" -d 'lang=en' -o /dev/null "$2/site/lang" || return
}

# Check if specified folder name is valid.
# When multiple folders wear the same name, first one is taken.
# $1: source code of main page
# $2: folder name selected by user
# stdout: folder ID
rapidgator_check_folder() {
    local -r HTML=$1
    local -r NAME=$2
    local FOLDERS FOL FOL_ID

    # Special treatment for root folder (alsways uses ID "0")
    if [ "$NAME" = 'root' ]; then
        echo 0
        return 0
    fi

    # <option value="ID">NAME</option>
    FOLDERS=$(parse_all_tag option <<< "$HTML") || return
    if [ -z "$FOLDERS" ]; then
        log_error 'No folder found, site updated?'
        return $ERR_FATAL
    fi

    log_debug 'Available folders:' $FOLDERS

    while IFS= read -r FOL; do
        if [ "$FOL" = "$NAME" ]; then
            FOL_ID=$(parse_attr "^<option.*>$FOL</option>" 'value' <<< "$HTML") || return
            echo "$FOL_ID"
            return 0
        fi
    done <<< "$FOLDERS"

    log_error "Invalid folder, choose from:" $FOLDERS
    return $ERR_BAD_COMMAND_LINE
}

# Get number of active remote uploads for an Rapidgator account
# $1: cookie file (logged into account)
# $2: base url
# stdout: number of active remote downloads
rapidgator_num_remote() {
    local TRY

    for TRY in 1 2 3; do
        curl -b "$1" -H 'X-Requested-With: XMLHttpRequest' \
            "$2/remotedl/RefreshCountDiv?_=$(date +%s)000" && return

        log_debug "Site did not answer. Retrying... [$TRY]"
        wait 30 || return
    done

    return $ERR_FATAL
}

# Output a file URL to download from Rapidgator
# $1: cookie file
# $2: rapidgator url
# stdout: real file download link
#         file name
rapidgator_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://rapidgator.net'
    local -r CAPTCHA_URL='/download/captcha'
    local ACCOUNT HTML REDIR FILE_ID FILE_NAME SESSION_ID JSON STATE
    local WAIT_TIME FORM RESP CHALL CAPTCHA_DATA ID

    rapidgator_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(rapidgator_login "$AUTH" "$COOKIE_FILE" \
            "$BASE_URL") || return
    fi

    # Also log headers to capture premium 'direct download' link
    HTML=$(curl --include -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return
    REDIR=$(grep_http_header_location_quiet <<< "$HTML")

    # Various (temporary) errors
    if [ -z "$HTML" ] || match '502 Bad Gateway' "$HTML" || \
        match 'Error 500' "$HTML"; then
        log_error 'Remote server error, maybe due to overload.'
        echo 120 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE

    # Various "File not found" responses
    elif match 'Error 404' "$HTML" || \
        match 'File not found' "$HTML" ||
        [[ "$REDIR" = */article/premium ]]; then
        return $ERR_LINK_DEAD
    fi

    # [premium] You have reached daily quota of downloaded information for premium accounts. At the moment, the quota is 15 GB
    # [free, anon] You have reached your daily downloads limit. Please try again later.
    if match 'You have reached.*daily.*\(quota\|limit\)' "$HTML"; then
        # We'll take it literally and wait till the next day
        # Note: Consider the time zone of their server (+4:00)
        local HOUR MIN TIME

        # Get current UTC time, prevent leading zeros
        TIME=$(date -u +'%k:%M') || return
        HOUR=${TIME%:*}
        MIN=${TIME#*:}

        log_error 'Daily limit reached.'
        echo $(( ((23 - ((HOUR + 4) % 24) ) * 60 + (61 - ${MIN#0}) ) * 60 ))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Try to parse file name from page title
    FILE_NAME=$(parse_tag_quiet 'title' <<< "$HTML")
    FILE_NAME=${FILE_NAME#Download file }

    # If this is a premium download, we already have the download link
    if [ "$ACCOUNT" = 'premium' ]; then
        # Extract premium download link from page
        if match 'Click here to download' "$HTML"; then
            parse 'premium_download_link' "'\(.\+\)'" <<< "$HTML" || return
            echo "$FILE_NAME"
            return 0
        fi

        # This may be a 'direct download'
        if [ -z "$REDIR" ]; then
            log_error 'Unexpected content. Site updated?'
            return $ERR_FATAL
        fi

        HTML=$(curl --head "$REDIR") || return

        # Parse and output file name
        echo "$REDIR"
        grep_http_header_content_disposition <<< "$HTML" || return
        return 0
    fi

    # Consider errors (enforced limits) which only occur for free users
    # You have reached your hourly downloads limit. Please, try again later.
    if match 'reached your hourly downloads limit' "$HTML"; then
        log_error 'Hourly limit reached.'
        echo 3600
        return $ERR_LINK_TEMP_UNAVAILABLE

    # You can`t download not more than 1 file at a time in free mode.
    elif match 'download not more than .\+ in free mode' "$HTML"; then
        log_error 'No parallel download allowed.'
        echo 120 # wait some arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE

    # You can download files up to 500 MB in free mode.
    # This file can be downloaded by premium only
    # Note: The regexp would also match the "parallel download" error above.
    elif match 'can.*download.*\(in free mode\|premium only\)' "$HTML"; then
        return $ERR_LINK_NEED_PERMISSIONS

    # Delay between downloads must be not less than 15 min.
    # Note: We cannot just look for the text by itself because it is
    #       always present as parts of the page's javascript code.
    elif match '^[[:space:]]\+Delay between downloads' "$HTML"; then
        WAIT_TIME=$(parse 'Delay between downloads' \
            'not less than \([[:digit:]]\+\) min' <<< "$HTML") || return

        log_error 'Forced delay between downloads.'
        echo $(( WAIT_TIME * 60 ))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Extract file ID
    FILE_ID=$(parse 'var fid' '=[[:space:]]\+\([[:digit:]]\+\)' <<< "$HTML") || return
    log_debug "File ID: $FILE_ID"

    # Parse wait time from page
    WAIT_TIME=$(parse 'var secs' '=[[:space:]]\+\([[:digit:]]\+\)' <<< "$HTML") || return

    # Request download session
    JSON=$(curl -b "$COOKIE_FILE" --referer "$URL" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H 'Accept: application/json, text/javascript, */*; q=0.01' \
        "$BASE_URL/download/AjaxStartTimer?fid=$FILE_ID") || return

    # Check status
    # Note: from '$(".btn-free").click(function(){...'
    STATE=$(parse_json 'state' <<< "$JSON") || return

    if [ "$STATE" = 'started' ]; then
        SESSION_ID=$(parse_json 'sid' <<< "$JSON") || return
    elif [ "$STATE" = 'error' ]; then
        log_error "Remote error: $(parse_json 'code' <<< "$JSON")"
        return $ERR_FATAL
    else
        log_error 'Unexpected state. Site updated?'
    fi

    log_debug "Session ID: '$SESSION_ID'"
    wait $WAIT_TIME seconds || return

    # Request download
    # Note: We *must* keep the new cookie.
    JSON=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" --referer "$URL" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H 'Accept: application/json, text/javascript, */*; q=0.01' \
        "$BASE_URL/download/AjaxGetDownloadLink?sid=$SESSION_ID") || return

    # Check status
    # Note: from 'function getDownloadLink() {...'
    STATE=$(parse_json 'state' <<< "$JSON") || return

    if [ "$STATE" = 'error' ]; then
        log_error "Remote error: $(parse_json 'code' <<< "$JSON")"
        return $ERR_FATAL
    elif [ "$STATE" != 'done' ]; then
        log_error 'Unexpected state. Site updated?'
        return $ERR_FATAL
    fi

    # Get main captcha page
    # Note: site uses multiple captcha services :-(
    HTML=$(curl -i -b "$COOKIE_FILE" --referer "$URL" \
        "$BASE_URL$CAPTCHA_URL") || return

    # Check HTTP response codes
    if match '^HTTP.*\(302\|500\)' "$HTML"; then
        log_error 'Captcha server overloaded.'
        echo 15 # wait some arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # emulate 'grep_form_by_id_quiet'
    FORM=$(grep_form_by_id "$HTML" 'captchaform' 2>/dev/null)

    # Solve each type of captcha separately
    if [ -n "$FORM" ]; then
        if match 'api\.solvemedia' "$FORM"; then
            log_debug 'Solve Media CAPTCHA found'

            RESP=$(solvemedia_captcha_process 'oy3wKTaFP368dkJiGUqOVjBR2rOOR7GR') || return
            { read CHALL; read ID; } <<< "$RESP"

            CAPTCHA_DATA="-d adcopy_challenge=$(uri_encode_strict <<< "$CHALL") -d adcopy_response=manual_challenge"

        else
            log_error "Unexpected content/captcha type: '$FORM'"
            return $ERR_FATAL
        fi

        log_debug "Captcha data: $CAPTCHA_DATA"

        # Get download link (Note: No quotes around $CAPTCHA_DATA!)
        HTML=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
            --referer "$BASE_URL$CAPTCHA_URL" \
            -d 'DownloadCaptchaForm%5Bcaptcha%5D=' \
            $CAPTCHA_DATA \
            "$BASE_URL$CAPTCHA_URL") || return

        if ! match 'Click here to download' "$HTML"; then
            local FAIL_COOKIE
            FAIL_COOKIE=$(parse_cookie_quiet 'failed_on_captcha' < "$COOKIE_FILE")
            log_debug "fail cookie: '$FAIL_COOKIE'"

            if match 'verification code is incorrect' "$HTML" || \
                [ "$FAIL_COOKIE" = '1' ]; then
                captcha_nack $ID
                log_debug 'Wrong captcha'
                return $ERR_CAPTCHA
            fi

            log_error 'Unexpected content. Site updated?'
            return $ERR_FATAL
        fi

        captcha_ack $ID
        log_debug 'Correct captcha'
    fi

    # Extract + output download link
    parse 'function getUrl' "'\(.\+\)'" 2  <<< "$HTML" || return
    echo "$FILE_NAME"
}

# Upload a file to Rapidgator
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
#         delete link
rapidgator_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://rapidgator.net'
    local HTML URL LINK DEL_LINK

    # Sanity checks
    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    if [ -n "$FOLDER" ] && match_remote_url "$FILE"; then
        log_error 'Folder selection only available for local uploads.'
        return $ERR_BAD_COMMAND_LINE

    elif [ -n "$ASYNC" ] && ! match_remote_url "$FILE"; then
        log_error 'Cannot upload local files asynchronously.'
        return $ERR_BAD_COMMAND_LINE

    elif [ -n "$ASYNC" -a "$DEST_FILE" != 'dummy' ]; then
        log_error 'Cannot rename a file uploaded asynchronously.'
        return $ERR_BAD_COMMAND_LINE
    fi

    rapidgator_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    # Login (don't care for account type)
    rapidgator_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" > /dev/null || return

    # Clear link list?
    if [ -n "$CLEAR" ]; then
        log_debug 'Clearing remote upload link list.'

        HTML=$(curl -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            "$BASE_URL/remotedl/delCompleteDownload")
    fi

    # Prepare upload
    if match_remote_url "$FILE"; then
        URL="$BASE_URL/remotedl/index"
    else
        URL="$BASE_URL/site/index"
    fi

    HTML=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    # Server sometimes returns an empty page
    if [ -z "$HTML" ]; then
        log_error 'Server sent empty page, maybe due to overload.'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Upload remote file
    if match_remote_url "$FILE"; then
        local ACC_ID QUEUE TYPE TRY NUM REM_LINKS RL FILE_ID

        # During synchronous remote uploads no other remote transfer
        # must run (Note: This will ease parsing considerably later on.)
        if [ -z "$ASYNC" ]; then
            NUM=$(rapidgator_num_remote "$COOKIE_FILE" "$BASE_URL") || return
            if [ $NUM -gt 0 ]; then
                log_error 'You have active remote downloads.'
                return $ERR_LINK_TEMP_UNAVAILABLE
            fi
        fi

        # Scrape account details from site
        ACC_ID=$(parse 'user_id =' 'id=\([[:digit:]]\+\)";' <<< "$HTML") || return
        QUEUE=$(parse 'queue =' 'queue=\([^"]\+\)";' <<< "$HTML") || return

        if match '^http://' "$FILE"; then
            TYPE=$(parse_all_attr 'http://</option>' 'value' <<< "$HTML") || return
        elif match '^ftp://' "$FILE"; then
            TYPE=$(parse_all_attr 'ftp://</option>' 'value' <<< "$HTML") || return
        else
            log_error 'Unsupported protocol for remote upload.'
            return $ERR_BAD_COMMAND_LINE
        fi

        log_debug "Queue: '$QUEUE'"
        log_debug "Account ID: '$ACC_ID'"
        log_debug "Upload type ID: '$TYPE'"

        HTML=$(curl -b "$COOKIE_FILE" -F "my_select=$TYPE" \
            -F 'login%5B2%5D=' -F 'password%5B2%5D=' \
            -F 'login%5B3%5D=' -F 'password%5B3%5D=' \
            -F 'login%5B4%5D=' -F 'password%5B4%5D=' \
            -F 'login%5B6%5D=' -F 'password%5B6%5D=' \
            -F 'login%5B8%5D=' -F 'password%5B8%5D=' \
            -F 'login%5B9%5D=' -F 'password%5B9%5D=' \
            -F 'login%5B10%5D=' -F 'password%5B10%5D=' \
            -F 'login%5B11%5D=' -F 'password%5B11%5D=' \
            -F "url=$FILE" \
            -F "queue=$QUEUE" -F "user_id=$ACC_ID" \
            -H 'X-Requested-With: XMLHttpRequest' \
            "$BASE_URL/remotedl/Downloadrequest") || return

        # Note: server *always* answers in russian
        if ! match 'Файл добавлен в базу данных' "$HTML"; then
            log_error 'Unexpected content. Site updated?'
            return $ERR_FATAL
        fi

        # If this is an async upload, we are done
        if [ -n "$ASYNC" ]; then
            log_error 'Once remote upload completed, check your account for link.'
            return $ERR_ASYNC_REQUEST
        fi

        # Keep checking progress
        NUM=1
        TRY=1
        while [ $NUM -gt 0 ]; do
            NUM=$(rapidgator_num_remote "$COOKIE_FILE" "$BASE_URL") || return

            log_debug "Wait for server to download the file... [$((TRY++))]"
            wait 15 || return # arbitrary, short wait time
        done

        # Upload done, find link
        HTML=$(curl -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            "$BASE_URL/remotedl/RefreshGridView?_=$(date +%s)000") || return

        REM_LINKS=$(parse_all_tag tr <<< "$HTML") || return

        while IFS= read -r RL; do
            # Find the (first) line containing our URL
            if match "$FILE" "$RL"; then
                # Note: error is *always* in russian
                if match 'Файл не доступен' "$RL"; then
                    log_error 'Remote server cannot access file or refuses to download it.'
                    return $ERR_FATAL
                fi

                FILE_ID=$(parse . 'getFileLink(\([[:digit:]]\+\),' <<< "$RL") || return
                break
            fi
        done <<< "$REM_LINKS"

        if [ -z "FILE_ID" ]; then
            log_error 'Could not get file ID. Site updated?'
            return $ERR_FATAL
        fi

        log_debug "File ID: '$FILE_ID'"

        # Do we need to rename the file?
        if [ "$DEST_FILE" != 'dummy' ]; then
            log_debug 'Renaming file'

            HTML=$(curl -b "$COOKIE_FILE" -F "id_rename=$FILE_ID" \
                -F 'type_rename=file' -F "new_name=$DEST_FILE" \
                -H 'X-Requested-With: XMLHttpRequest' \
                "$BASE_URL/filesystem/RenameSelected") || return

            match 'true' "$HTML" || \
                log_error 'Could not rename file. Site updated?'
        fi

        LINK="$BASE_URL/file/$FILE_ID"

    # Upload local file
    else
        local FOLDER_ID=0
        local JSON SESSION_ID START_TIME STATE FOLDER_ID UP_URL PROG_URL

        # If user choose a folder, check it now
        if [ -n "$FOLDER" ]; then
            FOLDER_ID=$(rapidgator_check_folder "$HTML" "$FOLDER") || return
        fi

        # Scrape URLs from site (upload server changes each time)
        UP_URL=$(parse 'var form_url' '"\(.\+\)";' <<< "$HTML") || return
        PROG_URL=$(parse 'var progress_url_srv' '"\(.\+\)";' <<< "$HTML") || return

        log_debug "Upload URL: '$UP_URL'"
        log_debug "Progress URL: '$PROG_URL'"
        log_debug "Folder ID: '$FOLDER_ID'"

        # Session ID is created this way (in uploadwidget.js):
        #   var i, uuid = "";
        #   for (i = 0; i < 32; i++) {
        #       uuid += Math.floor(Math.random() * 16).toString(16);
        #   }
        SESSION_ID=$(random h 32)
        START_TIME=$(date +%s)

        # Upload file
        HTML=$(curl_with_log --referer "$URL" -b "$COOKIE_FILE" \
            -F "file=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
            "$UP_URL$SESSION_ID&folder_id=$FOLDER_ID") || return

        # Get download URL
        JSON=$(curl --referer "$URL" -H "Origin: $BASE_URL" \
            -H 'Accept: application/json, text/javascript, */*; q=0.01' \
            "$PROG_URL&data%5B0%5D%5Buuid%5D=$SESSION_ID&data%5B0%5D%5Bstart_time%5D=$START_TIME") || return

        # Check status
        STATE=$(parse_json 'state' <<< "$JSON") || return
        if [ "$STATE" != 'done' ]; then
            log_error "Unexpected state: '$STATE'"
            return $ERR_FATAL
        fi

        LINK=$(parse_json 'download_url' <<< "$JSON") || return
        DEL_LINK=$(parse_json 'remove_url' <<< "$JSON") || return
    fi

    echo "$LINK"
    echo "$DEL_LINK"
}

# Delete a file from Rapidgator
# $1: cookie file
# $2: rapidgator (delete) link
rapidgator_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://rapidgator.net'
    local HTML ID UP_ID

    ID=$(parse . '/id/\([^/]\+\)/up_id/' <<< "$URL") || return
    UP_ID=$(parse . '/up_id/\(.\+\)$' <<< "$URL") || return

    log_debug "ID: '$ID'"
    log_debug "Up_ID: '$UP_ID'"

    rapidgator_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    HTML=$(curl -b "$COOKIE_FILE" "$URL") || return

    if match 'Do you really want to remove' "$HTML"; then
        HTML=$(curl -b "$COOKIE_FILE" -d "id=$ID" -d "up_id=$UP_ID" \
            "$BASE_URL/remove/remove") || return

        if match 'File successfully deleted' "$HTML"; then
            return 0
        fi
    elif match 'File not found' "$HTML"; then
        return $ERR_LINK_DEAD
    fi

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}

# List a rapidgator.net shared file folder URL
# $1: rapidgator.net link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
rapidgator_list() {
    local URL=$1
    local PAGE LINKS NAMES

    if ! match "${MODULE_RAPIDGATOR_REGEXP_URL}folder/" "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    PAGE=$(curl -L "$URL") || return
    PAGE=$(parse_all_quiet '=.td-for-select' '\(<a href=.*\)$' <<< "$PAGE")
    [ -z "$PAGE" ] && return $ERR_LINK_DEAD

    NAMES=$(parse_all . 'alt=..>[[:space:]]*\([^<]*\)' <<< "$PAGE")
    LINKS=$(parse_all_attr href <<< "$PAGE")

    list_submit "$LINKS" "$NAMES" 'http://rapidgator.net' || return
}

# Probe a download URL
# $1: cookie file
# $2: rapidgator url
# $3: requested capability list
# stdout: 1 capability per line
rapidgator_probe() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REDIR REQ_OUT FILE_NAME FILE_SIZE

    # Note: Should use rapidgator_switch_lang
    PAGE=$(curl --include -c "$COOKIE_FILE" -b 'lang=en' "$URL") || return
    REDIR=$(grep_http_header_location_quiet <<< "$PAGE")

    # Various "File not found" responses
    if match 'Error 404' "$PAGE" || \
        match 'File not found' "$PAGE" ||
        [[ "$REDIR" = */article/premium ]]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse_tag title <<< "$PAGE")
        FILE_NAME=${FILE_NAME#Download file }
        test "$FILE_NAME" && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'File size:' '<strong>\([^<]*\)' 1 <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
