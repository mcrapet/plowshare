#!/bin/bash
#
# bayfiles.com module
# Copyright (c) 2012 Plowshare team
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

MODULE_BAYFILES_REGEXP_URL="https\?://\(www\.\)\?bayfiles\.com/"

MODULE_BAYFILES_DOWNLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free-user account"
MODULE_BAYFILES_DOWNLOAD_RESUME=yes
MODULE_BAYFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_BAYFILES_UPLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free-user account
PRINT_ALL_LINKS,,print-all-links,,Print admin and delete links next to the download link"
MODULE_BAYFILES_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login (free-user or premium)
# i didn't test with a premium account but it should work (same API)
bayfiles_login() {
    local AUTH_FREE="$1"
    local APIURL="$2"

    local SESSION LOGIN_JSON_DATA

    # Must be tested with premium account
    IFS=":" read USER PASSWORD <<< "$AUTH_FREE"
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$(prompt_for_password) || return $ERR_LOGIN_FAILED
    fi
    LOGIN_JSON_DATA=$(curl "${APIURL}/account/login/${USER}/${PASSWORD}") || return
    SESSION=$(echo "$LOGIN_JSON_DATA" | parse 'session' 'session":"\([^"]*\)') || return $ERR_LOGIN_FAILED

    echo "$SESSION"
    return 0
}

# Output a bayiles file download URL
# $1: cookie file (unused here)
# $2: bayfiles url
# stdout: real file download link
# Same for free-user and anonymous user, not tested with premium
bayfiles_download() {
    eval "$(process_options bayfiles "$MODULE_BAYFILES_DOWNLOAD_OPTIONS" "$@")"

    local URL="$2"
    local APIURL='http://api.bayfiles.com/v1'
    local AJAX_URL='http://bayfiles.com/ajax_download'
    local PAGE FILE_URL FILENAME

    # Try to login (if $AUTH_FREE not null)
    if test -n "$AUTH_FREE"; then
        bayfiles_login "$AUTH_FREE" "$APIURL" >/dev/null || return
    fi

    # No way to download a file with the api
    PAGE=$(curl "$URL") || return

    if match 'The link is incorrect' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Now there are two cases, with small files, nothing changed and with
    # big ones, now there is a countdown timer and we have to wait 5min
    # between downloads
    if match 'Premium Download' "$PAGE"; then
        # Big files case

        local VFID DELAY TOKEN
        local JSON_COUNT DATA_DL

        # it's always print 5 min, don't need to match time
        if match 'Upgrade to premium or wait' "$PAGE"; then
            echo $((5*60))
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        VFID=$(echo "$PAGE" | parse "var vfid = " "= \([[:digit:]]\+\);") || return

        # If no delay were found, we try without
        DELAY=$(echo "$PAGE" | parse_quiet "var delay = " "= \([[:digit:]]\+\);")

        JSON_COUNT=$(curl -G --data "action=startTimer&vfid=$VFID" \
            $AJAX_URL) || return

        TOKEN=$(echo "$JSON_COUNT" |\
            parse 'token' 'token":"\([^"]*\)') || return

        wait $((DELAY)) "seconds" || return

        DATA_DL=$(curl --data "action=getLink&vfid=$VFID&token=$TOKEN" \
            $AJAX_URL) || return

        FILE_URL=$(echo "$DATA_DL" |\
            parse 'onclick' "\(http[^']*\)") || return
    else
        # Small files case, no countdown timer, no 5 min to wait between downloads
        # Maybe that this case work with a premium account

        FILE_URL=$(echo "$PAGE" | parse_attr 'class="highlighted-btn' 'href') || return
    fi

    echo "$FILE_URL"

    # Extract filename from $PAGE, work for both cases
    FILENAME=$(echo "$PAGE" | parse_attr_quiet 'title="' 'title')

    test "$FILENAME" && echo "$FILENAME"
}

# Upload a file to bayfiles
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link and if --print-all-links is used admin and delete links
bayfiles_upload() {
    eval "$(process_options bayfiles "$MODULE_BAYFILES_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local FILE="$2"
    local DESTFILE="$3"
    local APIURL='http://api.bayfiles.com/v1'

    local SESSION_GET UPLOAD_JSON_DATA UPLOAD_URL UPLOADED_FILE_JSON_DATA URL DELETE_URL ADMIN_URL

    # need a session argument at the end to get a link to upload into
    # the $AUTH_FREE account or nothing for anonymous users
    if test -n "$AUTH_FREE"; then
        SESSION_GET="?session="$(bayfiles_login "$AUTH_FREE" "$APIURL") || return
    else
        SESSION_GET=""
    fi

    UPLOAD_JSON_DATA=$(curl -b "$COOKIEFILE" "${APIURL}/file/uploadUrl${SESSION_GET}") || return

    # "/" seems to be the only backslashed char
    UPLOAD_URL=$(echo "$UPLOAD_JSON_DATA" |\
        parse 'uploadUrl' 'uploadUrl":"\([^"]*\)' |\
        replace '\/' '/') || return

    UPLOADED_FILE_JSON_DATA=$(curl_with_log -b "$COOKIEFILE"\
        -F "file=@$FILE;filename=$DESTFILE" "$UPLOAD_URL") || return

    URL=$(echo "$UPLOADED_FILE_JSON_DATA" |\
        parse 'downloadUrl' 'downloadUrl":"\([^"]*\)' |\
        replace '\/' '/') || return

    if test -n "$PRINT_ALL_LINKS"; then
        ADMIN_URL=$(echo "$UPLOADED_FILE_JSON_DATA" |\
            parse 'linksUrl' 'linksUrl":"\([^"]*\)' |\
            replace '\/' '/') || return

        DELETE_URL=$(echo "$UPLOADED_FILE_JSON_DATA" |\
            parse 'deleteUrl' 'deleteUrl":"\([^"]*\)' |\
            replace '\/' '/') || return

        echo "$URL ($ADMIN_URL) ($DELETE_URL)"
    else
        echo "$URL"
    fi
}
