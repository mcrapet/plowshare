# Plowshare depositfiles.com module
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

MODULE_DEPOSITFILES_REGEXP_URL='https\?://\(www\.\)\?\(depositfiles\.\(com\|org\)\)\|\(dfiles\.\(eu\|ru\)\)/'

MODULE_DEPOSITFILES_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_DEPOSITFILES_DOWNLOAD_RESUME=yes
MODULE_DEPOSITFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_DEPOSITFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_DEPOSITFILES_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
API,,api,,Use new upload method/non-public API"
MODULE_DEPOSITFILES_UPLOAD_REMOTE_SUPPORT=no

MODULE_DEPOSITFILES_LIST_OPTIONS=""
MODULE_DEPOSITFILES_LIST_HAS_SUBFOLDERS=no

MODULE_DEPOSITFILES_DELETE_OPTIONS=""
MODULE_DEPOSITFILES_PROBE_OPTIONS=""

# Static function. Proceed with login (free & gold account)
depositfiles_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT

    LOGIN_DATA='go=1&login=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.php" -b 'lang_current=en') || return

    if match 'recaptcha' "$LOGIN_RESULT"; then
        log_debug 'recaptcha solving required for login'

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LdRTL8SAAAAAE9UOdWZ4d0Ky-aeA7XfSqyWDM2m'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/login.php" -b 'lang_current=en' \
            -d "recaptcha_challenge_field=$CHALLENGE" \
            -d "recaptcha_response_field=$WORD") || return

        # <div class="error_message">Security code not valid.</div>
        if match 'code not valid' "$LOGIN_RESULT"; then
            captcha_nack $ID
            log_debug 'reCaptcha error'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug 'correct captcha'
    fi

    # <div class="error_message">Your password or login is incorrect</div>
    if match 'login is incorrect' "$LOGIN_RESULT"; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a depositfiles file download URL
# $1: cookie file
# $2: depositfiles.com url
# stdout: real file download link
depositfiles_download() {
    local COOKIEFILE=$1
    local URL=$2
    local -r BASE_URL='http://dfiles.eu'
    local START DLID WAITTIME DATA FID SLEEP FILE_URL

    if [ -n "$AUTH" ]; then
        depositfiles_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return
    fi

    if [ -s "$COOKIEFILE" ]; then
        START=$(curl -L -b "$COOKIEFILE" -b 'lang_current=en' "$URL") || return
    else
        START=$(curl -L -b 'lang_current=en' "$URL") || return
    fi

    if match "no_download_msg" "$START"; then
        # Please try again in 1 min until file processing is complete.
        if match 'html_download_api-temporary_unavailable' "$START"; then
            return $ERR_LINK_TEMP_UNAVAILABLE
        # Attention! You have exceeded the 20 GB 24-hour limit.
        elif match 'html_download_api-gold_traffic_limit' "$START"; then
            log_error 'Traffic limit exceeded (20 GB)'
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        return $ERR_LINK_DEAD
    fi


    if match "download_started()" "$START"; then
        FILE_URL=$(echo "$START" | parse_attr 'download_started()' 'href') || return
        echo "$FILE_URL"
        return 0
    fi

    DLID=$(echo "$START" | parse 'switch_lang' 'files%2F\([^"]*\)')
    log_debug "download ID: $DLID"
    if [ -z "$DLID" ]; then
        log_error "Can't parse download id, site updated"
        return $ERR_FATAL
    fi

    # 1. Check for error messages (first page)

    # - You have reached your download time limit.<br>Try in 10 minutes or use GOLD account.
    if match 'download time limit' "$START"; then
        WAITTIME=$(echo "$START" | parse 'Try in' "in \([[:digit:]:]*\) minutes")
        if [[ $WAITTIME -gt 0 ]]; then
            echo $((WAITTIME * 60))
        fi
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    DATA=$(curl --data 'gateway_result=1' "$BASE_URL/en/files/$DLID") || return

    # 2. Check if we have been redirected to initial page
    if match '<input type="button" value="Gold downloading"' "$DATA"; then
        log_error 'FIXME'
        return $ERR_FATAL
    fi

    # 3. Check for error messages (second page)

    # - Attention! You used up your limit for file downloading!
    # - Attention! Connection limit has been exhausted for your IP address!
    if match 'limit for file\|exhausted for your IP' "$DATA"; then
        WAITTIME=$(echo "$DATA" | \
            parse 'class="html_download_api-limit_interval"' 'l">\([^<]*\)<')
        log_debug "limit reached: waiting $WAITTIME seconds"
        echo $((WAITTIME))
        return $ERR_LINK_TEMP_UNAVAILABLE

    # - Such file does not exist or it has been removed for infringement of copyrights.
    elif match 'html_download_api-not_exists' "$DATA"; then
        return $ERR_LINK_DEAD

    # - We are sorry, but all downloading slots for your country are busy.
    elif match 'html_download_api-limit_country' "$DATA"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FID=$(echo "$DATA" | parse 'var[[:space:]]fid[[:space:]]=' "[[:space:]]'\([^']*\)") ||
        { log_error "cannot find fid"; return $ERR_FATAL; }

    SLEEP=$(echo "$DATA" | parse "download_waiter_remain" ">\([[:digit:]]\+\)<") ||
        { log_error "cannot get wait time"; return $ERR_FATAL; }

    # Usual wait time is 60 seconds
    wait $((SLEEP + 1)) seconds || return

    DATA=$(curl --location "$BASE_URL/get_file.php?fid=$FID") || return

    # reCaptcha page (challenge forced)
    if match 'load_recaptcha();' "$DATA"; then

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LdRTL8SAAAAAE9UOdWZ4d0Ky-aeA7XfSqyWDM2m'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        DATA=$(curl --get --location -b 'lang_current=en' \
            -H 'X-Requested-With: XMLHttpRequest' --referer "$URL" \
            -d "fid=$FID" -d "response=$WORD" \
            -d "challenge=$CHALLENGE" "$BASE_URL/get_file.php") || return

        if match '=.downloader_file_form' "$DATA"; then
            captcha_ack $ID
            log_debug 'correct captcha'

            echo "$DATA" | parse_form_action
            return 0
        fi

        captcha_nack $ID
        log_debug 'reCaptcha error'
        return $ERR_CAPTCHA
    fi

    echo "$DATA" | parse_form_action
}

# Upload a file to depositfiles
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: depositfiles download link
depositfiles_upload() {
    local COOKIEFILE=$1
    local FILE=$2
    local DESTFILE=$3
    local -r BASE_URL='http://dfiles.eu'
    local DATA DL_LINK DEL_LINK SIZE MAX_SIZE #used by both methods
    local FORM_HTML FORM_URL FORM_UID FORM_GO FORM_AGREE # used by old method
    local UP_URL STATUS MEMBER_KEY # used by new method

    if [ -n "$AUTH" ]; then
        depositfiles_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return
    fi

    if [ -n "$API" ]; then
        if [ -n "$AUTH" ]; then
            DATA=$(curl -b "$COOKIEFILE" "$BASE_URL") || return
            MEMBER_KEY=$(echo "$DATA" | parse_attr 'upload index_upload' \
                'sharedkey') || return
        fi

        DATA=$(curl -b "$COOKIEFILE" "$BASE_URL/api/upload/regular") || return
        STATUS=$(echo "$DATA" | parse_json 'status') || return

        if [ "$STATUS" != 'OK' ]; then
            log_error "Unexpected remote error: $STATUS"
            return $ERR_FATAL
        fi

        UP_URL=$(echo "$DATA" | parse_json 'upload_url') || return
        MAX_SIZE=$(echo "$DATA" | parse_json 'max_file_size_mb') || return
        MAX_SIZE=$(translate_size "${MAX_SIZE}MB") || return

        log_debug "MEMBER_KEY: '$MEMBER_KEY'"
        log_debug "UP_URL: $UP_URL"
    else
        DATA=$(curl -b "$COOKIEFILE" "$BASE_URL") || return

        FORM_HTML=$(grep_form_by_id "$DATA" 'upload_form') || return
        FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
        MAX_SIZE=$(echo "$FORM_HTML" | parse_form_input_by_name 'MAX_FILE_SIZE')
        FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'UPLOAD_IDENTIFIER')
        FORM_GO=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'go')
        FORM_AGREE=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'agree')
    fi

    # File size limit check
    SIZE=$(get_filesize "$FILE") || return
    if [ "$SIZE" -gt "$MAX_SIZE" ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$API" ]; then
        # Note: The website does an OPTIONS request to $UP_URL first, but
        #       curl cannot do this.

        DATA=$(curl_with_log -b "$COOKIEFILE" \
            -F "files=@$FILE;filename=$DESTFILE" -F 'format=html5'  \
            -F "member_passkey=$MEMBER_KEY" -F 'fm=_root' -F 'fmh=' \
            "$UP_URL") || return

        STATUS=$(echo "$DATA" | parse_json 'status') || return

        if [ "$STATUS" != 'OK' ]; then
            log_error "Unexpected remote error: $STATUS"
            return $ERR_FATAL
        fi

        DL_LINK=$(echo "$DATA" | parse_json 'download_url') || return
        DEL_LINK=$(echo "$DATA" | parse_json 'delete_url') || return
    else
        DATA=$(curl_with_log -b "$COOKIEFILE"    \
            -F "MAX_FILE_SIZE=$FORM_MAXFSIZE"    \
            -F "UPLOAD_IDENTIFIER=$FORM_UID"     \
            -F "go=$FORM_GO"                     \
            -F "agree=$FORM_AGREE"               \
            -F "files=@$FILE;filename=$DESTFILE" \
            -F "padding=$(add_padding)"          \
            "$FORM_URL") || return

        # Invalid local or global uploads dirs configuration
        if match 'Invalid local or global' "$DATA"; then
            log_error 'upload failure, rename file and/or extension and retry'
            return $ERR_FATAL
        fi

        DL_LINK=$(echo "$DATA" | parse 'ud_download_url[[:space:]]' "'\([^']*\)'") || return
        DEL_LINK=$(echo "$DATA" | parse 'ud_delete_url' "'\([^']*\)'") || return
    fi

    echo "$DL_LINK"
    echo "$DEL_LINK"
}

# Delete a file on depositfiles
# (authentication not required, we can delete anybody's files)
# $1: cookie file (unused here)
# $2: delete link
depositfiles_delete() {
    local URL=$2
    local PAGE

    PAGE=$(curl "$URL") || return

    # File has been deleted and became inaccessible for download.
    if matchi 'File has been deleted' "$PAGE"; then
        return 0

    # No such downlodable file or incorrect removal code.
    else
        log_error 'bad deletion code'
        return $ERR_FATAL
    fi
}

# List a depositfiles shared file folder URL
# $1: depositfiles.com link
# $2: recurse subfolders (ignored here)
# stdout: list of links
depositfiles_list() {
    local URL=$1
    local PAGE LINKS NAMES

    if ! match "${MODULE_DEPOSITFILES_REGEXP_URL}folders" "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    PAGE=$(curl -L "$URL") || return
    PAGE=$(echo "$PAGE" | parse_all 'target="_blank"' \
        '\(<a href="http[^<]*</a>\)') || return $ERR_LINK_DEAD

    NAMES=$(echo "$PAGE" | parse_all_attr '<a' title)
    LINKS=$(echo "$PAGE" | parse_all_attr '<a' href)

    list_submit "$LINKS" "$NAMES" || return
}

# http://img3.depositfiles.com/js/upload_utils.js
# check_form() > add_padding()
add_padding() {
    local I STR
    for (( I = 0 ; I < 750 ; I++ )); do
        STR="$STR "
    done
    echo "$STR$STR$STR$STR"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: depositfiles url
# $3: requested capability list
# stdout: 1 capability per line
depositfiles_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_NAME FILE_SIZE

    PAGE=$(curl --location -b 'lang_current=en' "$URL") || return

    match 'This file does not exist' "$PAGE" && return $ERR_LINK_DEAD
    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse '=.file_size' '\(unescape([^)]\+)\)' -1 <<< "$PAGE" | replace_all '%' '\')
        FILE_NAME=$(printf '%b' "$FILE_NAME" | parse_tag '=.file_name' b)
        test "$FILE_NAME" && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag '=.file_size' b  <<< "$PAGE" | replace_all '&nbsp;' '')
        test "$FILE_SIZE" && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
