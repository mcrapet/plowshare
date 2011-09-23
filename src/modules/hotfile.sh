#!/bin/bash
#
# hotfile.com module
# Copyright (c) 2010-2011 Plowshare team
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
AUTH,a:,auth:,USER:PASSWORD,Free-membership or Premium account"
MODULE_HOTFILE_DOWNLOAD_RESUME=no
MODULE_HOTFILE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_HOTFILE_LIST_OPTIONS=""

# Output an hotfile.com file download URL (anonymous or premium)
# $1: cookie file
# $2: hotfile.com url
# stdout: real file download link
hotfile_download() {
    eval "$(process_options hotfile "$MODULE_HOTFILE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL="${2}&lang=en"

    if match 'hotfile\.com/list/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return $ERR_FATAL
    fi

    # Try to get the download link using premium credentials (if $AUTH not null)
    # Some code duplicated from core.sh, post_login().
    if [ -n "$AUTH" ]; then
        USER="${AUTH%%:*}"
        PASSWORD="${AUTH#*:}"

        log_notice "Starting download process: $USER/$(sed 's/./*/g' <<< "$PASSWORD")"
        FILE_URL=$(curl "http://api.hotfile.com/?action=getdirectdownloadlink&username=${USER}&password=${PASSWORD}&link=${URL}") || return

        # Hotfile API error messages starts with a dot, if no dot then the download link is available
        if [ ${FILE_URL:0:1} == "." ]; then
            log_error "login request failed (bad login/password or link invalid/removed)"
            return $ERR_LOGIN_FAILED
        fi

        echo "$FILE_URL"
        return 0
    fi

    BASE_URL='http://hotfile.com'

    while retry_limit_not_reached || return; do
        WAIT_HTML=$(curl -c $COOKIEFILE "$URL") || return

        # "This file is either removed due to copyright claim or is deleted by the uploader."
        if match '\(404 - Not Found\|or is deleted\)' "$WAIT_HTML"; then
            log_debug "File not found"
            return $ERR_LINK_DEAD
        fi

        SLEEP=$(echo "$WAIT_HTML" | parse 'timerend=d.getTime()' '+\([[:digit:]]\+\);') ||
            { log_error "can't get sleep time"; return $ERR_FATAL; }

        test "$CHECK_LINK" && return 0

        # Send (post) form
        local FORM_HTML=$(grep_form_by_name "$WAIT_HTML" 'f')
        local form_url=$(echo "$FORM_HTML" | parse_form_action)
        local form_action=$(echo "$FORM_HTML" | parse_form_input_by_name 'action')
        local form_tm=$(echo "$FORM_HTML" | parse_form_input_by_name 'tm')
        local form_tmhash=$(echo "$FORM_HTML" | parse_form_input_by_name 'tmhash')
        local form_wait=$(echo "$FORM_HTML" | parse_form_input_by_name 'wait')
        local form_waithash=$(echo "$FORM_HTML" | parse_form_input_by_name 'waithash')
        local form_upidhash=$(echo "$FORM_HTML" | parse_form_input_by_name 'upidhash')

        SLEEP=$((SLEEP / 1000))
        wait $((SLEEP)) seconds || return

        WAIT_HTML2=$(curl -b $COOKIEFILE --data "action=${form_action}&tm=${form_tm}&tmhash=${form_tmhash}&wait=${form_wait}&waithash=${form_waithash}&upidhash=${form_upidhash}" \
            "${BASE_URL}${form_url}") || return

        # Direct download (no captcha)
        if match 'Click here to download' "$WAIT_HTML2"; then
            local LINK=$(echo "$WAIT_HTML2" | parse_attr 'click_download' 'href')
            FILEURL=$(curl -b $COOKIEFILE --include "$LINK" | grep_http_header_location)
            echo "$FILEURL"
            return 0

        elif match 'You reached your hourly traffic limit' "$WAIT_HTML2"; then
            # grep 2nd occurrence of "timerend=d.getTime()+<number>" (function starthtimer)
            WAIT_TIME=$(echo "$WAIT_HTML2" | sed -n '/starthtimer/,$p' | parse 'timerend=d.getTime()' '+\([[:digit:]]\+\);') ||
                { log_error "can't get wait time"; return $ERR_FATAL; }
            WAIT_TIME=$((WAIT_TIME / 60000))
            wait $((WAIT_TIME)) minutes || return
            continue

        # reCaptcha page
        elif match 'api\.recaptcha\.net' "$WAIT_HTML2"
        then
            local FORM2_HTML=$(grep_form_by_order "$WAIT_HTML2" 2)
            local form2_url=$(echo "$FORM2_HTML" | parse_form_action)
            local form2_action=$(echo "$FORM2_HTML" | parse_form_input_by_name 'action')

            local PUBKEY='6LfRJwkAAAAAAGmA3mAiAcAsRsWvfkBijaZWEvkD'
            local IMAGE_FILENAME=$(recaptcha_load_image $PUBKEY)

            if [ -n "$IMAGE_FILENAME" ]; then
                TRY=1

                while retry_limit_not_reached || return; do
                    log_debug "reCaptcha manual entering (loop $TRY)"
                    (( TRY++ ))

                    WORD=$(captcha_process "$IMAGE_FILENAME")

                    rm -f $IMAGE_FILENAME

                    [ -n "$WORD" ] && break

                    log_debug "empty, request another image"
                    IMAGE_FILENAME=$(recaptcha_reload_image $PUBKEY "$IMAGE_FILENAME")
                done

                CHALLENGE=$(recaptcha_get_challenge_from_image "$IMAGE_FILENAME")

                HTMLPAGE=$(curl -b $COOKIEFILE --data \
                    "action=${form2_action}&recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" \
                    "${BASE_URL}${form2_url}") || return

                if match 'Wrong Code. Please try again.' "$HTMLPAGE"; then
                    log_debug "wrong captcha"
                    break
                fi

                local LINK=$(echo "$HTMLPAGE" | parse_attr 'click_download' 'href')
                if [ -n "$LINK" ]; then
                    log_debug "correct captcha"

                    FILEURL=$(curl -b $COOKIEFILE --include "$LINK" | grep_http_header_location)
                    echo "$FILEURL"
                    return 0
                fi
            fi

            log_error "reCaptcha error"
            break

        else
            log_error "Unknown state, give up!"
            break
        fi
    done

    return $ERR_FATAL
}

# List a hotfile shared file folder URL
# $1: HOTFILE_URL
# stdout: list of links
hotfile_list() {
    local URL="$1"

    if ! match 'hotfile\.com/list/' "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    PAGE=$(curl "$URL" | grep 'hotfile.com/dl/')

    if test -z "$PAGE"; then
        log_error "Wrong directory list link"
        return $ERR_FATAL
    fi

    # First pass : print debug message
    while read LINE; do
        FILENAME=$(echo "$LINE" | parse 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILENAME"
    done <<< "$PAGE"

    # Second pass : print links (stdout)
    while read LINE; do
        LINK=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$LINK"
    done <<< "$PAGE"

    return 0
}
