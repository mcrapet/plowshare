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
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free account"
MODULE_BAYFILES_DOWNLOAD_RESUME=yes
MODULE_BAYFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_BAYFILES_UPLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Free account"
MODULE_BAYFILES_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login (free-user or premium)
# i didn't test with a premium account but it should work (same API)
bayfiles_login() {
    local AUTH_FREE=$1
    local APIURL=$2

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

    local URL=$2
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

        TOKEN=$(echo "$JSON_COUNT" | parse_json token) || return

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

    # Extract filename from $PAGE, work for both cases
    FILENAME=$(echo "$PAGE" | parse_attr_quiet 'title="' 'title')

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to bayfiles
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link + admin link
bayfiles_upload() {
    eval "$(process_options bayfiles "$MODULE_BAYFILES_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE=$1
    local FILE=$2
    local DESTFILE=$3
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

    UPLOAD_URL=$(echo "$UPLOAD_JSON_DATA" | parse_json 'uploadUrl') || return

    UPLOADED_FILE_JSON_DATA=$(curl_with_log -b "$COOKIEFILE"\
        -F "file=@$FILE;filename=$DESTFILE" "$UPLOAD_URL") || return

    URL=$(echo "$UPLOADED_FILE_JSON_DATA" | \
        parse_json 'downloadUrl') || return
    DELETE_URL=$(echo "$UPLOADED_FILE_JSON_DATA" | \
        parse_json 'deleteUrl') || return
    ADMIN_URL=$(echo "$UPLOADED_FILE_JSON_DATA" | \
        parse_json 'linksUrl') || return

    echo "$URL"
    echo "$DELETE_URL"
    echo "$ADMIN_URL"
}
