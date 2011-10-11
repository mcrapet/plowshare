#!/bin/bash
#
# rapidshare.com module
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

MODULE_RAPIDSHARE_REGEXP_URL="https\?://\(www\.\|rs[[:digit:]][0-9a-z]*\.\)\?rapidshare\.com/"

MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use Premium-Zone account"
MODULE_RAPIDSHARE_DOWNLOAD_RESUME=no
MODULE_RAPIDSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

MODULE_RAPIDSHARE_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use an account"
MODULE_RAPIDSHARE_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use an account"

# Output a rapidshare file download URL (anonymous and premium)
# $1: cookie file (unused here)
# $2: rapidshare.com url
# stdout: real file download link
rapidshare_download() {
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS" "$@")"

    local URL="$2"

    # Two URL formats:
    # http://rapidshare.com/files/429795114/arc02f.rar
    # http://rapidshare.com/#!download|774tl4|429794114|arc02f.rar|5249
    if match '.*/#!download|' "$URL"; then
        FILEID=$(echo "$URL" | cut -d'|' -f3)
        FILENAME=$(echo "$URL" | cut -d'|' -f4)
    else
        FILEID=$(echo "$URL" | cut -d'/' -f5)
        FILENAME=$(echo "$URL" | cut -d'/' -f6)
    fi
    test "$FILEID" -a "$FILENAME" || \
        { log_error "Cannot parse fileID/filename from URL: $URL"; return $ERR_FATAL; }

    # Arbitrary wait (local variables)
    NO_FREE_SLOT_IDLE=125
    STOP_FLOODING=360

    while retry_limit_not_reached || return; do
        BASE_APIURL="https://api.rapidshare.com/cgi-bin/rsapi.cgi?sub=download&fileid=${FILEID}&filename=${FILENAME}"

        if test "$AUTH"; then
            IFS=":" read USER PASSWORD <<< "$AUTH"
            PARAMS="&login=$USER&password=$PASSWORD"
        else
            PARAMS=""
        fi

        PAGE=$(curl "${BASE_APIURL}${PARAMS}") || return
        local ERROR=$(echo "$PAGE" | parse_quiet "ERROR:" "ERROR:[[:space:]]*\(.*\)")

        if match "need to wait" "$ERROR"; then
            WAIT=$(echo "$ERROR" | parse "." "wait \([[:digit:]]\+\) seconds") || return

            test "$CHECK_LINK" && return 0
            log_notice "Server has asked to wait $WAIT seconds"
            wait $WAIT seconds || return
            continue

        elif match "File \(deleted\|not found\|ID invalid\)" "$ERROR"; then
            return $ERR_LINK_DEAD

        elif match "flooding" "$ERROR"; then
            log_debug "Server said we are flooding it."
            echo $STOP_FLOODING
            return $ERR_LINK_TEMP_UNAVAILABLE

        elif match "slots" "$ERROR"; then
            log_debug "Server said there is no free slots available"
            echo $NO_FREE_SLOT_IDLE
            return $ERR_LINK_TEMP_UNAVAILABLE

        elif test "$ERROR"; then
            log_error "website error: $ERROR"
            return $ERR_FATAL
        fi

        # DL:$hostname,$dlauth,$countdown,$md5hex
        IFS="," read RSHOST DLAUTH WTIME CRC <<< "${PAGE#DL:}"

        if [ -z "$RSHOST" -o -z "$DLAUTH" -o -z "$WTIME" -o -z "$CRC" ]; then
            log_error "unexpected page content"
            return $ERR_FATAL
        fi

        test "$CHECK_LINK" && return 0

        log_debug "file md5: $CRC"
        break
    done

    wait $((WTIME)) seconds || return

    # https is only available for RapidPro customers
    local BASEURL="://$RSHOST/cgi-bin/rsapi.cgi?sub=download"

    if test "$AUTH"; then
        echo "https$BASEURL&fileid=$FILEID&filename=$FILENAME&dlauth=$DLAUTH&login=$USER&password=$PASSWORD"
    else
        echo "http$BASEURL&fileid=$FILEID&filename=$FILENAME&dlauth=$DLAUTH"
    fi
    echo "$FILENAME"
}

# Upload a file to rapidshare using rsapi - http://images.rapidshare.com/apidoc.txt
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download_url
rapidshare_upload() {
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"

    local FILE="$2"
    local DESTFILE="$3"

    if ! test "$AUTH"; then
        log_error "Anonymous users cannot upload files"
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    local USER="${AUTH%%:*}"
    local PASSWORD="${AUTH#*:}"

    if [ "$AUTH" = "$PASSWORD" ]; then
        PASSWORD=$(prompt_for_password) || return $ERR_LOGIN_FAILED
    fi

    SERVER_NUM=$(curl "http://api.rapidshare.com/cgi-bin/rsapi.cgi?sub=nextuploadserver") || return
    log_debug "upload server is rs$SERVER_NUM"

    UPLOAD_URL="https://rs${SERVER_NUM}.rapidshare.com/cgi-bin/rsapi.cgi"

    INFO=$(curl_with_log -F "sub=upload" \
            -F "filecontent=@$FILE;filename=$DESTFILE" \
            -F "login=$USER" -F "password=$PASSWORD" "$UPLOAD_URL") || return

    if ! match '^COMPLETE' "$INFO"; then
        log_error "incomplete upload"
        return $ERR_FATAL
    fi

    # Expected answer:
    # fileid,filename,filesize,md5hex
    IFS="," read FILEID FILENAME SZ <<< "${INFO:9}"

    echo "http://rapidshare.com/files/${FILEID}/$FILENAME"
}

# Delete a file on rapidshare
# $1: rapidshare (download) link
rapidshare_delete() {
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_DELETE_OPTIONS" "$@")"

    local URL="$1"

    if ! test "$AUTH"; then
        log_error "Anonymous users cannot delete files"
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    local USER="${AUTH%%:*}"
    local PASSWORD="${AUTH#*:}"

    if [ "$AUTH" = "$PASSWORD" ]; then
        PASSWORD=$(prompt_for_password) || return $ERR_LOGIN_FAILED
    fi

    # Two possible URL format
    if match '.*/#!download|' "$URL"; then
        FILEID=$(echo "$URL" | cut -d'|' -f3)
    else
        FILEID=$(echo "$URL" | cut -d'/' -f5)
    fi

    if [ -z "$FILEID" ]; then
        log_error "cannot parse fileid from URL"
        return $ERR_FATAL
    fi

    log_debug "FileID=$FILEID"

    RESPONSE=$(curl -F "login=$USER" -F "password=$PASSWORD" \
        -F "sub=deletefiles" -F "files=$FILEID" \
        'https://api.rapidshare.com/cgi-bin/rsapi.cgi') || return

    if [ "$RESPONSE" != 'OK' ]; then
        log_error "unexpected result ($RESPONSE)"
        return $ERR_FATAL
    fi

    log_debug "file removed successfully"
    return 0
}
