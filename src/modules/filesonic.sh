#!/bin/bash
#
# filesonic.com module
# Copyright (c) 2011 Plowshare team
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

MODULE_FILESONIC_REGEXP_URL="http://\(www\.\)\?filesonic\.com/"
MODULE_FILESONIC_DOWNLOAD_OPTIONS=""
MODULE_FILESONIC_DOWNLOAD_CONTINUE=no
MODULE_FILESONIC_LIST_OPTIONS=""

# Output an filesonic.com file download URL (anonymous)
# $1: filesonic url string
# stdout: real file download link
filesonic_download() {
    eval "$(process_options filesonic "$MODULE_FILESONIC_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    local ID=$(echo "$URL" | parse_quiet '\/file\/' 'file\/\([^/]*\)')
    if [ -z "$ID" ]; then
        log_error "Cannot parse URL to extract file id (mandatory)"
        return 253
    fi
    URLID="http://www.filesonic.com/file/$ID"

    COOKIES=$(create_tempfile)

    MAINPAGE=$(curl -c $COOKIES "$URL") || return 1

    # do not obtain filename from "<span>Filename:" because it is shortened
    # with "..." if too long; instead, take it from title
    FILENAME=$(echo "$MAINPAGE" |parse_quiet "<title>" ">Download \(.*\) for free")

    PAGE=$(curl -b $COOKIES -H "X-Requested-With: XMLHttpRequest" --referer "$URLID?start=1" --data "" "$URLID?start=1") || return 1

    if match 'File does not exist' "$PAGE"; then
        log_debug "File not found"
        rm -f $COOKIES
        return 254
    fi
    test "$CHECK_LINK" && return 255

    # Cases: download link, captcha, wait
    # captcha/wait can redirect to any of these three cases
    FOLLOWS=0
    while [ $FOLLOWS -lt 5 ]; do
        (( FOLLOWS++ ))

        # download link
        if match 'Start download now' "$PAGE"; then
            FILE_URL=$(echo $PAGE |parse_quiet 'Start download now' 'href="\([^"]*\)"')
            break

        # captcha
        else if match 'Please Enter Captcha' "$PAGE"; then
            local PUBKEY='6LdNWbsSAAAAAIMksu-X7f5VgYy8bZiiJzlP83Rl'
            IMAGE_FILENAME=$(recaptcha_load_image $PUBKEY)

            if [ -z "$IMAGE_FILENAME" ]; then
                log_error "reCaptcha error"
                rm -f $COOKIES
                return 1
            fi

            TRY=1
            while retry_limit_not_reached || return 3; do
                log_debug "reCaptcha manual entering (loop $TRY)"
                (( TRY++ ))

                WORD=$(recaptcha_display_and_prompt "$IMAGE_FILENAME")

                rm -f $IMAGE_FILENAME

                [ -n "$WORD" ] && break

                log_debug "empty, request another image"
                IMAGE_FILENAME=$(recaptcha_reload_image $PUBKEY "$IMAGE_FILENAME")
            done

            CHALLENGE=$(recaptcha_get_challenge_from_image "$IMAGE_FILENAME")

            PAGE=$(curl -b $COOKIES -H "X-Requested-With: XMLHttpRequest" --referer "$URL" --data \
              "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" "$URL?start=1") || return 1

            match 'Please Enter Captcha' "$PAGE" && log_error "wrong captcha"

        # wait
        else if match 'countDownDelay' "$PAGE"; then
            SLEEP=$(echo "$PAGE" |parse_quiet 'var countDownDelay = ' 'countDownDelay = \([0-9]*\);') || return 1
            wait $SLEEP seconds || return 2

            # for wait time > 5min. these values may not be present
            # it just means we need to try again so the following code is fine
            TM=$(echo "$PAGE" |parse_quiet "name='tm' value='" "name='tm' value='\([0-9]*\)'")
            TM_HASH=$(echo "$PAGE" |parse_quiet "name='tm_hash' value='" "name='tm_hash' value='\([a-f0-9]*\)'")

            PAGE=$(curl -b $COOKIES -H "X-Requested-With: XMLHttpRequest" --referer "$URL" --data "tm=$TM&tm_hash=$TM_HASH" "$URL?start=1") || return 1

        else
            log_error "No match. Site update?"
            return 1

        fi; fi; fi
    done

    rm -f $COOKIES

    echo "$FILE_URL"
    test "$FILENAME" && echo "$FILENAME"

    return 0
}

# List a filesonic public folder URL
# $1: filesonic url
# stdout: list of links
filesonic_list() {
    set -e
    eval "$(process_options filesonic "$MODULE_FILESONIC_LIST_OPTIONS" "$@")"
    URL=$1

    if ! match 'filesonic\.com\/folder\/' "$URL"; then
        log_error "This is not a folder"
        return 1
    fi

    PAGE=$(curl "$URL" | grep '<a href="http://www.filesonic.com/file/')

    if test -z "$PAGE"; then
        log_error "Wrong folder link (no download link detected)"
        return 1
    fi

    # First pass: print file names (debug)
    echo "$PAGE" | while read LINE; do
        FILENAME=$(echo "$LINE" | parse 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILENAME"
    done

    # Second pass: print links (stdout)
    echo "$PAGE" | while read LINE; do
        LINK=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$LINK"
    done

    return 0
}
