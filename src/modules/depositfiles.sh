#!/bin/bash
#
# depositfiles.com module
# Copyright (c) 2010-2012 Plowshare team
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

MODULE_DEPOSITFILES_REGEXP_URL="http://\(\w\+\.\)\?depositfiles\.com/"

MODULE_DEPOSITFILES_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_DEPOSITFILES_DOWNLOAD_RESUME=yes
MODULE_DEPOSITFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

MODULE_DEPOSITFILES_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_DEPOSITFILES_UPLOAD_REMOTE_SUPPORT=no

MODULE_DEPOSITFILES_DELETE_OPTIONS=""
MODULE_DEPOSITFILES_LIST_OPTIONS=""

# Static function. Proceed with login (free & gold account)
depositfiles_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT

    LOGIN_DATA='go=1&login=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.php" '-b lang_current=en') || return

    if match 'recaptcha' "$LOGIN_RESULT"; then
        log_debug "recaptcha solving required for login"

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LdRTL8SAAAAAE9UOdWZ4d0Ky-aeA7XfSqyWDM2m'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        local USER="${AUTH%%:*}"
        local PASSWORD="${AUTH#*:}"

        LOGIN_RESULT=$(curl -c "$COOKIE_FILE" -b 'lang_current=en' --data \
            "go=1&login=$USER&password=$PASSWORD&recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" \
            "$BASE_URL/login.php") || return

        # <div class="error_message">Security code not valid.</div>
        if match 'code not valid' "$LOGIN_RESULT"; then
            recaptcha_nack $ID
            log_debug "reCaptcha error"
            return $ERR_CAPTCHA
        fi

        recaptcha_ack $ID
        log_debug "correct captcha"
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
    eval "$(process_options depositfiles "$MODULE_DEPOSITFILES_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL="$2"
    local BASE_URL='http://depositfiles.com'
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
        fi

        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

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

    DATA=$(curl --data "gateway_result=1" "$BASE_URL/en/files/$DLID") || return

    # 2. Check if we have been redirected to initial page
    if match '<input type="button" value="Gold downloading"' "$DATA"; then
        log_error "FIXME"
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

        DATA=$(curl --get --location --data \
            "fid=$FID&challenge=$CHALLENGE&response=$WORD" \
            -H "X-Requested-With: XMLHttpRequest" --referer "$URL" \
            "$BASE_URL/get_file.php") || return

        if match 'Download the file' "$DATA"; then
            recaptcha_ack $ID
            log_debug "correct captcha"

            echo "$DATA" | parse_form_action
            return 0
        fi

        recaptcha_nack $ID
        log_debug "reCaptcha error"
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
    eval "$(process_options depositfiles "$MODULE_DEPOSITFILES_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local FILE="$2"
    local DESTFILE="$3"
    local DATA DL_LINK DEL_LINK

    if [ -n "$AUTH" ]; then
        depositfiles_login "$AUTH" "$COOKIEFILE" 'http://depositfiles.com' || return
    fi

    DATA=$(curl -b "$COOKIEFILE" 'http://depositfiles.com') || return

    local FORM_HTML FORM_URL FORM_MAXFSIZE FORM_UID FORM_GO FORM_AGREE
    FORM_HTML=$(grep_form_by_id "$DATA" 'upload_form')
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action)
    FORM_MAXFSIZE=$(echo "$FORM_HTML" | parse_form_input_by_name 'MAX_FILE_SIZE')
    FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'UPLOAD_IDENTIFIER')
    FORM_GO=$(echo "$FORM_HTML" | parse_form_input_by_name 'go')
    FORM_AGREE=$(echo "$FORM_HTML" | parse_form_input_by_name 'agree')

    DATA=$(curl_with_log -b "$COOKIEFILE" \
        -F "MAX_FILE_SIZE=$FORM_MAXFSIZE"    \
        -F "UPLOAD_IDENTIFIER=$FORM_UID"     \
        -F "go=$FORM_GO"                     \
        -F "agree=$FORM_AGREE"               \
        -F "files=@$FILE;filename=$DESTFILE" \
        "$FORM_URL") || return

    DL_LINK=$(echo "$DATA" | parse 'ud_download_url[[:space:]]' "'\([^']*\)'") || return
    DEL_LINK=$(echo "$DATA" | parse 'ud_delete_url' "'\([^']*\)'") || return

    echo "$DL_LINK"
    echo "$DEL_LINK"
}

# Delete a file on depositfiles
# (authentication not required, we can delete anybody's files)
# $1: delete link
depositfiles_delete() {
    eval "$(process_options depositfiles "$MODULE_DEPOSITFILES_DELETE_OPTIONS" "$@")"

    local URL="$1"
    local PAGE

    PAGE=$(curl "$URL") || return

    # File has been deleted and became inaccessible for download.
    if matchi 'File has been deleted' "$PAGE"; then
        return 0

    # No such downlodable file or incorrect removal code.
    else
        log_error "bad deletion code"
        return $ERR_FATAL
    fi
}

# List a depositfiles shared file folder URL
# $1: depositfiles.com link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
depositfiles_list() {
    local URL="$1"
    local PAGE LINKS FILE_NAME FILE_URL

    if ! match 'depositfiles\.com/\(../\)\?folders/' "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    PAGE=$(curl -L "$URL") || return
    LINKS=$(echo "$PAGE" | parse_all 'target="_blank"' \
        '\(<a href="http[^<]*<\/a>\)') || return $ERR_LINK_DEAD

    # First pass : print debug message
    while read LINE; do
        FILE_NAME=$(echo "$LINE" | parse_attr '<a' 'title')
        log_debug "$FILE_NAME"
    done <<< "$LINKS"

    # Second pass : print links (stdout)
    while read LINE; do
        FILE_URL=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$FILE_URL"
    done <<< "$LINKS"
}
