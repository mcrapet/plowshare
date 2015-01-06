# Plowshare 180upload.com module
# Copyright (c) 2012-2013 Plowshare team
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
#
# Note: This module is similar to filebox and zalaa (for upload)

MODULE_180UPLOAD_REGEXP_URL='https\?://\(www\.\)\?180upload\.com/'

MODULE_180UPLOAD_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_180UPLOAD_DOWNLOAD_RESUME=yes
MODULE_180UPLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_180UPLOAD_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_180UPLOAD_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_180UPLOAD_UPLOAD_REMOTE_SUPPORT=no

MODULE_180UPLOAD_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("" or "free" or "premium") on success
180upload_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE ERR MSG NAME

    # Try to revive old session...
    if COOKIES=$(storage_get 'cookies'); then
        echo "$COOKIES" > "$COOKIE_FILE"
    fi

    # ... and check login status
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' "$BASE_URL") || return

    if match 'Login' "$PAGE"; then
        log_debug 'Cached cookies invalid, deleting storage entry'
        storage_set 'cookies'

        [ -n "$AUTH_FREE" ] || return 0

        LOGIN_DATA='op=login&redirect=&login=$USER&password=$PASSWORD'
        PAGE=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
            "${BASE_URL}" -b 'lang=english') || return

        # Check for errors
        # Note: Successful login redirects and sets cookies 'login' and 'xfss'
        # Get error message, if any
        ERR=$(parse_tag_quiet "class='err'" 'b' <<< "$PAGE")

        if [ -n "$ERR" ]; then
            log_debug "Remote error: $ERR"
            return $ERR_LOGIN_FAILED
        fi

        storage_set 'cookies' "$(cat "$COOKIE_FILE")"
        MSG='logged in as'
    else
        MSG='reused login for'
    fi

    # Get username
    NAME=$(parse_cookie 'login' < "$COOKIE_FILE") || return
    log_debug "Successfully $MSG member '$NAME'"
    echo 'free'
}

# Output a 180upload.com file download URL
# $1: cookie file
# $2: 180upload.com url
# stdout: real file download link
180upload_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://180upload.com/'
    local PAGE ERR PUBKEY RESP CHALL ID CAPTCHA_DATA
    local FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_DD FORM_METHOD_F FORM_METHOD_P

    180upload_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" > /dev/null || return

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return

    # File Not Found, Copyright infringement issue, file expired or deleted by its owner.
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_DD=$(parse_form_input_by_name 'down_direct' <<< "$FORM_HTML") || return
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")
    FORM_METHOD_P=$(parse_form_input_by_name_quiet 'method_premium' <<< "$FORM_HTML")

    # Check for Captcha
    if match 'api\.solvemedia\.com' "$FORM_HTML"; then
        log_debug 'Solve Media CAPTCHA found'

        PUBKEY='MIqUIMADf7KbDRf0ANI-9wLP.8iJSG9N'
        RESP=$(solvemedia_captcha_process $PUBKEY) || return
        { read CHALL; read ID; } <<< "$RESP"

        CAPTCHA_DATA="-F adcopy_challenge=$CHALL -F adcopy_response=none"
    elif match 'RecaptchaOptions' "$FORM_HTML"; then
        log_debug 'reCaptcha found'

        local WORD
        PUBKEY='6LeEc8wSAAAAAJG8vzd61DufFYS_I6nXwMkl4dhI'
        RESP=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALL; read ID; } <<< "$RESP"

        CAPTCHA_DATA="-F recaptcha_challenge_field=$CHALL -F recaptcha_response_field=$WORD"
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -F "op=$FORM_OP" -F "id=$FORM_ID" -F "rand=$FORM_RAND" \
        -F 'referer='    -F "method_free=$FORM_METHOD_F" \
        -F "method_premium=$FORM_METHOD_P" $CAPTCHA_DATA \
        -F "down_direct=$FORM_DD" "$URL") || return

    # Get error message, if any
    ERR=$(parse_tag_quiet '<div class="err"' 'div' <<< "$PAGE")

    if [ -n "$ERR" ]; then
        if match 'Wrong captcha' "$ERR"; then
            log_error 'Wrong captcha'
            captcha_nack "$ID"
            return $ERR_CAPTCHA
        fi

        log_debug 'Correct captcha'
        captcha_ack "$ID"
        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    log_debug 'Correct captcha'
    captcha_ack "$ID"

    parse_attr 'id="lnk_download"' 'href' <<< "$PAGE" || return
    parse_tag 'class="style1"' 'span' <<< "$PAGE" || return
}

# Upload a file to filebox
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download_url
180upload_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://180upload.com/'
    local PAGE SIZE MAX_SIZE UPLOAD_ID STATUS_URL
    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_TMP_SRV

    # Check for forbidden file extensions
    case ${DEST_FILE##*.} in
        php|pl|cgi|py|sh|shtml)
            log_error 'File extension is forbidden. Try renaming your file.'
            return $ERR_FATAL
            ;;
    esac

    180upload_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" > /dev/null || return

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' "$BASE_URL") || return
    MAX_SIZE=$(parse 'Up to ' 'to \([[:digit:]]\+\) Mb' <<< "$PAGE") || return
    readonly MAX_SIZE=$(( MAX_SIZE * 1048576 )) # convert MiB to B

    SIZE=$(get_filesize "$FILE") || return
    if [ "$SIZE" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_UTYPE=$(parse_form_input_by_name 'upload_type' <<< "$FORM_HTML") || return
    FORM_SESS=$(parse_form_input_by_name_quiet 'sess_id' <<< "$FORM_HTML")
    FORM_TMP_SRV=$(parse_form_input_by_name 'srv_tmp_url' <<< "$FORM_HTML") || return
    log_debug "Server URL: '$FORM_TMP_SRV'"

    UPLOAD_ID=$(random dec 12)
    PAGE=$(curl "${FORM_TMP_SRV}/status.html?${UPLOAD_ID}=$DEST_FILE=180upload.com") || return

    # Sanity check. Avoid failure after effective upload
    if match '>404 Not Found<' "$PAGE"; then
        log_error 'upstream error (404)'
        return $ERR_FATAL
    fi

    PAGE=$(curl_with_log --include -b "$COOKIE_FILE" \
        -F "upload_type=$FORM_UTYPE"   -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" -F "file_1=@$FILE;filename=$DEST_FILE" \
        --form-string "file_1_descr=$DESCRIPTION" \
        --form-string "link_rcpt=$TOEMAIL" \
        -F 'tos=1' -F 'submit_btn= Upload! ' \
        "${FORM_ACTION}${UPLOAD_ID}") || return

    STATUS_URL=$(grep_http_header_location <<< "$PAGE") || return
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' $STATUS_URL) || return

    # Parse and output download and delete link
    parse 'Download Link' '>\(http[^<]\+\)<' 1 <<< "$PAGE" || return
    parse 'Delete Link' '>\(http[^<]\+\)<' 1 <<< "$PAGE" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: 180upload url
# $3: requested capability list
# stdout: 1 capability per line
180upload_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L -b 'lang=english' "$URL") || return

    # File Not Found, Copyright infringement issue, file expired or deleted by its owner.
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    # Note: all info parsed from HTML comments on the page
    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'center nowrap' 'b' <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag 'Size:' 'small' <<< "$PAGE") && \
            FILE_SIZE=${FILE_SIZE#(} && FILE_SIZE=${FILE_SIZE% bytes)} && \
            echo "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
