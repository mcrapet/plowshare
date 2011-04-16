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

MODULE_FILESONIC_REGEXP_URL="http://\(www\.\)\?filesonic\.[a-z]\+/"
MODULE_FILESONIC_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or premium account"
MODULE_FILESONIC_DOWNLOAD_CONTINUE=no
MODULE_FILESONIC_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or premium account"
MODULE_FILESONIC_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or premium account"
MODULE_FILESONIC_LIST_OPTIONS=""


# Proceed with login (free-membership or premium)
filesonic_login() {
    AUTH=$1
    COOKIES=$2
    BASEURL=$3

    LOGIN_DATA='email=$USER&password=$PASSWORD'
    LOGIN=$(post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" \
        "$BASEURL/user/login" "-H X-Requested-With:XMLHttpRequest -H Accept:application/json")

    if ! test "$LOGIN"; then
        log_debug "Login error"
        return 1
    fi

    STATUS=$(echo "$LOGIN" | parse_quiet '"status":"[^"]*"' '"status":"\([^"]*\)"')
    if [ "$STATUS" != "success" ]; then
        log_debug "Login failed: $STATUS"
        return 1
    fi

    ROLE=$(parse_cookie "role" < "$COOKIES")
    log_notice "Successfully logged in as $ROLE member"

    return 0
}

# Output an filesonic.com file download URL (anonymous)
# $1: filesonic url string
# stdout: real file download link
filesonic_download() {
    eval "$(process_options filesonic "$MODULE_FILESONIC_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    local ID=$(echo "$URL" | parse_quiet '\/file\/' 'file\/\([^/]*\)')
    if ! test "$ID"; then
        log_error "Cannot parse URL to extract file id (mandatory)"
        return 253
    fi

    # update URL if there is a specific .ccTLD location from there
    BASEURL=$(basename_url "$URL")
    LOCATION=$(curl -I "$BASEURL" | grep_http_header_location)
    if test "$LOCATION"; then
        BASEURL=$(basename_url "$LOCATION")
    fi
    URL="$BASEURL/file/$ID"

    COOKIES=$(create_tempfile)

    # obtain mainpage first (unauthenticated) to get filename
    MAINPAGE=$(curl -c "$COOKIES" "$URL") || {
        rm -f "$COOKIES"
        return 1
    }

    # do not obtain filename from "<span>Filename:" because it is shortened
    # with "..." if too long; instead, take it from title
    FILENAME=$(echo "$MAINPAGE" | parse_quiet "<title>" ">Download \(.*\) for free")

    # Attempt to authenticate
    if test "$AUTH"; then
        filesonic_login "$AUTH" "$COOKIES" "$BASEURL" || {
            rm -f "$COOKIES"
            return 1
        }

        FILE_URL=$(curl -I -b "$COOKIES" "$URL" | grep_http_header_location)
        if ! test "$FILE_URL"; then
            log_error "No link received (most likely premium account expired)"
            rm -f "$COOKIES"
            return 1
        fi

    # Normal user
    else
        PAGE=$(curl -b "$COOKIES" -H "X-Requested-With: XMLHttpRequest" \
                    --referer "$URL?start=1" --data "" "$URL?start=1")

        if match 'File does not exist' "$PAGE"; then
            log_debug "File not found"
            rm -f "$COOKIES"
            return 254
        fi
        if test "$CHECK_LINK"; then
            rm -f "$COOKIES"
            return 255
        fi

        # Cases: download link, <400MB, captcha, wait
        # captcha/wait can redirect to any of the other cases
        FOLLOWS=0
        while [ $FOLLOWS -lt 5 ]; do
            (( FOLLOWS++ ))

            # download link
            if match 'Start download now' "$PAGE"; then
                FILE_URL=$(echo $PAGE | parse_quiet 'Start download now' 'href="\([^"]*\)"')
                break

            # free users can download files < 400MB
            elif match 'download is larger than 400Mb.' "$PAGE"; then
                log_error "You're trying to download file larger than 400MB (only premium users can)."
                rm -f "$COOKIES"
                return 255

            # captcha
            elif match 'Please Enter Captcha' "$PAGE"; then
                local PUBKEY='6LdNWbsSAAAAAIMksu-X7f5VgYy8bZiiJzlP83Rl'
                IMAGE_FILENAME=$(recaptcha_load_image $PUBKEY)

                if ! test "$IMAGE_FILENAME"; then
                    log_error "reCaptcha error"
                    rm -f "$COOKIES"
                    return 1
                fi

                TRY=1
                while retry_limit_not_reached || { rm -f "$COOKIES"; return 3; }; do
                    log_debug "reCaptcha manual entering (loop $TRY)"
                    (( TRY++ ))

                    WORD=$(recaptcha_display_and_prompt "$IMAGE_FILENAME")

                    rm -f $IMAGE_FILENAME

                    test "$WORD" && break

                    log_debug "empty, request another image"
                    IMAGE_FILENAME=$(recaptcha_reload_image $PUBKEY "$IMAGE_FILENAME")
                done

                CHALLENGE=$(recaptcha_get_challenge_from_image "$IMAGE_FILENAME")

                DATA="recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD"
                PAGE=$(curl -b "$COOKIES" -H "X-Requested-With: XMLHttpRequest" \
                            --referer "$URL" --data "$DATA" "$URL?start=1")

                match 'Please Enter Captcha' "$PAGE" && log_error "wrong captcha"

            # wait
            elif match 'countDownDelay' "$PAGE"; then
                SLEEP=$(echo "$PAGE" | parse_quiet 'var countDownDelay = ' 'countDownDelay = \([0-9]*\);')
                wait $SLEEP seconds || {
                    rm -f "$COOKIES"
                    return 2
                }

                # for wait time > 5min. these values may not be present
                # it just means we need to try again so the following code is fine
                TM=$(echo "$PAGE" | parse_attr "name='tm'" "value")
                TM_HASH=$(echo "$PAGE" | parse_attr "name='tm_hash'" "value")

                PAGE=$(curl -b "$COOKIES" -H "X-Requested-With: XMLHttpRequest" \
                            --referer "$URL" --data "tm=$TM&tm_hash=$TM_HASH" "$URL?start=1")

            else
                log_error "No match. Site update?"
                rm -f "$COOKIES"
                return 1

            fi
        done
    fi

    rm -f "$COOKIES"

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

    if ! test "$PAGE"; then
        log_error "Wrong folder link (no download link detected)"
        return 1
    fi

    # First pass: print file names (debug)
    echo "$PAGE" | while read LINE; do
        FILENAME=$(echo "$LINE" | parse_quiet 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILENAME"
    done

    # Second pass: print links (stdout)
    echo "$PAGE" | while read LINE; do
        LINK=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$LINK"
    done

    return 0
}

# Upload a file to filesonic
# $1: file name to upload
# $2: upload as file name (optional, defaults to $1)
# $3: member only, upload in folder id (optional, defaults to 0 for root)
# stdout: download link on filesonic
filesonic_upload() {
    set -e
    eval "$(process_options filesonic "$MODULE_FILESONIC_UPLOAD_OPTIONS" "$@")"

    local FILE=$1
    local DESTFILE=${2:-$FILE}
    local FOLDERID=${3:-0}
    local URL="http://www.filesonic.com"

    # update URL if there is a specific .ccTLD location from there
    LOCATION=$(curl -I "$URL" | grep_http_header_location)
    if test "$LOCATION"; then
        URL=$(basename_url "$LOCATION")
    fi

    COOKIES=$(create_tempfile)
    FOLDER=""

    # Attempt to authenticate
    if test "$AUTH"; then
        filesonic_login "$AUTH" "$COOKIES" "$URL" || {
            rm -f "$COOKIES"
            return 1
        }
        FOLDER="-F folderId=$FOLDERID"
    fi

    # get main page to pick up an upload server
    PAGE=$(curl -b "$COOKIES" "$URL") || return 1
    SERVER=$(echo "$PAGE" | parse_quiet 'uploadServerHostname' "\s*=\s'*\([^']*\)';")

    if ! test "$SERVER"; then
        log_error "Can't find an upload server, site updated?"
        return 1
    fi

    # prepare upload file id - browser uses the following javascript, we can do it in bash
    # "upload_"+new Date().getTime()+"_<PHPSESSID>_"+Math.floor(Math.random()*90000)
    PHPSESSID=$(parse_cookie "PHPSESSID" < "$COOKIES")
    ID="upload_$(date '+%s')123_${PHPSESSID}_$RANDOM"

    # send file and get Location to completed URL
    # Note: explicitely remove "Expect: 100-continue" header that curl wants to send
    STATUS=$(curl -D - -b "$COOKIES" --referer "$URL" -H "Expect:" \
        -F "files[]=@$FILE;filename=$(basename_file "$DESTFILE")" $FOLDER \
        "http://$SERVER/?callbackUrl=$URL/upload-completed/:uploadProgressId&X-Progress-ID=$ID")

    if ! test "$STATUS"; then
        log_error "Upload error"
        rm -f "$COOKIES"
        return 1
    elif match 'An error occurred' "$STATUS"; then
        log_error "Upload failed: server error"
        rm -f "$COOKIES"
        return 1
    fi
    COMPLETED=$(echo "$STATUS" | grep_http_header_location)

    # get information
    INFOS=$(curl -b "$COOKIES" -e "$URL" "$COMPLETED")
    STATUSCODE=$(echo "$INFOS" | parse_quiet '"statusCode":[0-9]*' '"statusCode":\([0-9]*\)')
    STATUSMESSAGE=$(echo "$INFOS" | parse_quiet '"statusMessage":"[^"]*"' '"statusMessage":"\([^"]*\)"')

    if ! test "$STATUSCODE"; then
        log_error "Upload failed (no info)"
        rm -f "$COOKIES"
        return 1
    elif [ $STATUSCODE -ne 0 ]; then
        log_error "Upload failed: $STATUSMESSAGE ($STATUSCODE)"
        rm -f "$COOKIES"
        return 1
    fi
    log_debug "Upload succeeded: $STATUSMESSAGE"

    # get download link
    LINKID=$(echo "$INFOS" | parse_quiet '"linkId":"[^"]*"' '"linkId":"\([^"]*\)"')
    BROWSE=$(curl -b "$COOKIES" -H "X-Requested-With: XMLHttpRequest" \
        -e "$URL" "$URL/filesystem/generate-link/$LINKID")
    LINK=$(echo "$BROWSE" | parse_attr 'id="URL_' 'value')

    rm -f "$COOKIES"

    if ! test "$LINK"; then
        log_error "Can't parse download link, site updated?"
        return 1
    fi

    echo "$LINK"

    return 0
}

# Delete a file on filesonic (requires an account)
# $1: download link (must be a file that account uploaded)
# stdout: download link on filesonic
filesonic_delete() {
    set -e
    eval "$(process_options filesonic "$MODULE_FILESONIC_DELETE_OPTIONS" "$@")"

    if ! test "$AUTH"; then
        log_error "Anonymous users cannot delete links."
        return 1
    fi

    URL=$1
    local ID=$(echo "$URL" | parse_quiet '\/file\/' 'file\/\([^/]*\)')
    if ! test "$ID"; then
        log_error "Cannot parse URL to extract file id (mandatory)"
        return 253
    fi

    # update URL if there is a specific .ccTLD location from there
    URL=$(basename_url "$URL")
    LOCATION=$(curl -I "$URL" | grep_http_header_location)
    if test "$LOCATION"; then
        URL=$(basename_url "$LOCATION")
    fi

    COOKIES=$(create_tempfile)

    # Attempt to authenticate
    filesonic_login "$AUTH" "$COOKIES" "$URL" || {
        rm -f "$COOKIES"
        return 1
    }

    # Delete file, identifier is "F"+ID
    DELETE=$(curl -b "$COOKIES" -H "Accept: application/json" \
                -H "X-Requested-With: XMLHttpRequest" \
                --referer "$URL/filesystem/browse" \
                --data "files%5B%5D=F$ID" \
                "$URL/filesystem/delete")

    rm -f "$COOKIES"

    if ! test "$DELETE"; then
        log_debug "Delete error"
        return 1
    elif match 'Item not found' "$DELETE"; then
        log_error "Not found or already deleted"
        return 254
    fi

    STATUS=$(echo "$DELETE" | parse_quiet '"status":"[^"]*"' '"status":"\([^"]*\)"')
    if [ "$STATUS" != "success" ]; then
        log_debug "Delete failed: $STATUS"
        return 1
    fi

    log_notice "File deleted"
    return 0
}
