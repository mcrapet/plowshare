#!/bin/bash
#
# hotfile.com module
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

MODULE_HOTFILE_REGEXP_URL="http://\(www\.\)\?hotfile\.com/"

MODULE_HOTFILE_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Premium account"
MODULE_HOTFILE_DOWNLOAD_RESUME=no
MODULE_HOTFILE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_HOTFILE_UPLOAD_OPTIONS="
AUTH,a:,auth:,EMAIL:PASSWORD,User account (mandatory)"
MODULE_HOTFILE_UPLOAD_REMOTE_SUPPORT=no

MODULE_HOTFILE_LIST_OPTIONS=""

# Output a hotfile.com file download URL
# $1: cookie file
# $2: hotfile.com url
# stdout: real file download link
hotfile_download() {
    eval "$(process_options hotfile "$MODULE_HOTFILE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local URL="${2}&lang=en"
    local BASE_URL='http://hotfile.com'
    local FILE_URL ROLE WAIT_HTML WAIT_HTML2 SLEEP LINK

    if match 'hotfile\.com/list/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return $ERR_FATAL
    fi

    # Try to get the download link using premium credentials (if $AUTH not null)
    # Some code duplicated from core.sh, post_login().
    if [ -n "$AUTH" ]; then
        local USER="${AUTH%%:*}"
        local PASSWORD="${AUTH#*:}"

        if [ "$AUTH" = "$PASSWORD" ]; then
            PASSWORD=$(prompt_for_password) || return $ERR_LOGIN_FAILED
        fi

        ROLE=$(curl --get -d "username=$USER" -d "password=$PASSWORD" \
            -d 'action=getuserinfo' 'http://api.hotfile.com/') || return
        if match 'is_premium=0' "$ROLE"; then
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        FILE_URL=$(curl "http://api.hotfile.com/?action=getdirectdownloadlink&username=${USER}&password=${PASSWORD}&link=${URL}") || return

        # Hotfile API error messages starts with a dot, if no dot then the download link is available
        if [ "${FILE_URL:0:1}" = '.' ]; then
            log_error "login request failed (bad login/password or link invalid/removed)"
            return $ERR_LOGIN_FAILED
        fi

        echo "$FILE_URL"
        return 0
    fi

    WAIT_HTML=$(curl -c "$COOKIEFILE" "$URL") || return

    # "This file is either removed due to copyright claim or is deleted by the uploader."
    if match '\(404 - Not Found\|or is deleted\)' "$WAIT_HTML"; then
        return $ERR_LINK_DEAD
    fi

    SLEEP=$(echo "$WAIT_HTML" | parse 'timerend=d.getTime()' '+\([[:digit:]]\+\);') ||
        { log_error "can't get sleep time"; return $ERR_FATAL; }

    test "$CHECK_LINK" && return 0

    # Send (post) form
    local FORM_HTML FORM_URL FORM_ACTION FORM_TM FORM_TMHASH FORM_WAIT FORM_WAITHASH FORM_UPIDHASH
    FORM_HTML=$(grep_form_by_name "$WAIT_HTML" 'f') || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'action')
    FORM_TM=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'tm')
    FORM_TMHASH=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'tmhash')
    FORM_WAIT=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'wait')
    FORM_WAITHASH=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'waithash')
    FORM_UPIDHASH=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'upidhash')

    wait $((SLEEP / 1000)) seconds || return

    WAIT_HTML2=$(curl -b $COOKIEFILE -d "action=$FORM_ACTION" \
        -d "tm=$FORM_TM" -d "tmhash=$FORM_TMHASH" \
        -d "wait=$FORM_WAIT" -d "waithash=$FORM_WAITHASH" \
        -d "upidhash=$FORM_UPIDHASH" \
        "${BASE_URL}$FORM_URL") || return

    # Direct download (no captcha)
    if match 'Click here to download' "$WAIT_HTML2"; then
        LINK=$(echo "$WAIT_HTML2" | parse_attr 'click_download' 'href') || return
        FILE_URL=$(curl -b "$COOKIEFILE" --include "$LINK" | grep_http_header_location)
        echo "$FILE_URL"
        return 0

    elif match 'You reached your hourly traffic limit' "$WAIT_HTML2"; then
        # grep 2nd occurrence of "timerend=d.getTime()+<number>" (function starthtimer)
        WAIT_TIME=$(echo "$WAIT_HTML2" | sed -n '/starthtimer/,$p' | parse 'timerend=d.getTime()' '+\([[:digit:]]\+\);')
        echo $((WAIT_TIME / 1000))
        return $ERR_LINK_TEMP_UNAVAILABLE

    # reCaptcha page
    elif match 'api\.recaptcha\.net' "$WAIT_HTML2"; then

        local FORM2_HTML FORM2_URL FORM2_ACTION HTMLPAGE
        FORM2_HTML=$(grep_form_by_order "$WAIT_HTML2" 2)
        FORM2_URL=$(echo "$FORM2_HTML" | parse_form_action)
        FORM2_ACTION=$(echo "$FORM2_HTML" | parse_form_input_by_name_quiet 'action')

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LfRJwkAAAAAAGmA3mAiAcAsRsWvfkBijaZWEvkD'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        HTMLPAGE=$(curl -b "$COOKIEFILE" -d "action=$FORM2_ACTION" \
            -d "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" \
            "${BASE_URL}$FORM2_URL") || return

        if match 'Wrong Code. Please try again.' "$HTMLPAGE"; then
            captcha_nack $ID
            log_error "Wrong captcha"
            return $ERR_CAPTCHA
        fi

        LINK=$(echo "$HTMLPAGE" | parse_attr 'click_download' 'href')
        if [ -n "$LINK" ]; then
            captcha_ack $ID
            log_debug "correct captcha"

            FILE_URL=$(curl -b "$COOKIEFILE" --include "$LINK" | grep_http_header_location)
            echo "$FILE_URL"
            return 0
        fi
    fi

    log_error "Unknown state, give up!"
    return $ERR_FATAL
}

# Upload a file to hotfile using official API: http://api.hotfile.com/
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download_url
hotfile_upload() {
    eval "$(process_options hotfile "$MODULE_HOTFILE_UPLOAD_OPTIONS" "$@")"

    local FILE=$2
    local DESTFILE=$3
    local SERVER URL FILE_SIZE UPID DATA

    test "$AUTH" || return $ERR_LINK_NEED_PERMISSIONS

    local USER="${AUTH%%:*}"
    local PASSWORD="${AUTH#*:}"

    if [ "$AUTH" = "$PASSWORD" ]; then
        PASSWORD=$(prompt_for_password) || return $ERR_LOGIN_FAILED
    fi

    # Answer: one server per line
    SERVER=$(curl 'http://api.hotfile.com/?action=getuploadserver&count=1') || return
    URL="http://${SERVER}/segmentupload.php"

    FILE_SIZE=$(get_filesize "$FILE")

    UPID=$(curl --get -d 'action=start' -d "size=$FILE_SIZE" \
        "$URL") || return
    log_error "upload id: $UPID"

    DATA=$(curl -F 'action=upload' \
        -F "id=$UPID" \
        -F 'offset=0' \
        -F "segment=@$FILE" \
        "$URL") || return

    if [ "$DATA" = 'OK' ]; then
        DATA=$(curl -F 'action=finish' \
            -F "id=$UPID" \
            -F "name=$DESTFILE" \
            -F "username=$USER" \
            -F "password=$PASSWORD" \
            "$URL") || return

        if match_remote_url "$DATA"; then
            echo "$DATA"
            return 0
        fi
    fi

    log_error "remote error: $DATA"
    return $ERR_FATAL
}

# List a hotfile shared file folder URL
# $1: hotfile folder url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
hotfile_list() {
    local URL=$1
    local PAGE NUM LINKS FILE_NAME FILE_URL

    if ! match 'hotfile\.com/list/' "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    PAGE=$(curl "$URL") || return
    NUM=$(echo "$PAGE" | parse ' files)' '(\([[:digit:]]*\) files')
    log_debug "There is/are $NUM file(s) in the folder"

    LINKS=$(echo "$PAGE" | grep 'hotfile.com/dl/')
    test "$LINKS" || return $ERR_LINK_DEAD

    # First pass : print debug message
    while read LINE; do
        FILE_NAME=$(echo "$LINE" | parse_tag_quiet a)
        log_debug "$FILE_NAME"
    done <<< "$LINKS"

    # Second pass : print links (stdout)
    while read LINE; do
        FILE_URL=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$FILE_URL"
    done <<< "$LINKS"
}
