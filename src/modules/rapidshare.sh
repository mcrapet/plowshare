#!/bin/bash
#
# rapidshare.com module
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

MODULE_RAPIDSHARE_REGEXP_URL="https\?://\(www\.\|rs[[:digit:]][0-9a-z]*\.\)\?rapidshare\.com/"

MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_RAPIDSHARE_DOWNLOAD_RESUME=no
MODULE_RAPIDSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

MODULE_RAPIDSHARE_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account (mandatory)"
MODULE_RAPIDSHARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_RAPIDSHARE_DELETE_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account (mandatory)"

# Output a rapidshare file download URL
# $1: cookie file (unused here)
# $2: rapidshare.com url
# stdout: real file download link
rapidshare_download() {
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS" "$@")"

    local URL=$2
    local BASE_URL='https://api.rapidshare.com/cgi-bin/rsapi.cgi'
    local FILEID FILENAME USER PASSWORD COOKIE PAGE ERROR WAIT
    local IS_PREMIUM=0

    # Two possible URL format
    # http://rapidshare.com/files/429795114/arc02f.rar
    # http://rapidshare.com/#!download|774tl4|429794114|arc02f.rar|5249
    if match '.*/#!download|' "$URL"; then
        FILEID=$(echo "$URL" | cut -d'|' -f3)
        FILENAME=$(echo "$URL" | cut -d'|' -f4)
    else
        FILEID=$(echo "$URL" | cut -d'/' -f5)
        FILENAME=$(echo "$URL" | cut -d'/' -f6)
    fi

    if [ -z "$FILEID" -o -z "$FILENAME" ]; then
        log_error "Cannot parse fileID/filename from URL: $URL"
        return $ERR_FATAL
    fi

    if test "$AUTH"; then
        local DETAILS CUR_DATE END_DATE

        split_auth "$AUTH" USER PASSWORD || return

        DETAILS=$(curl -d 'sub=getaccountdetails' \
            -d "login=$USER" -d "password=$PASSWORD" \
            -d 'withcookie=1' -d 'withpublicid=0' \
            "$BASE_URL") || return

        # "cookie" parameter overrides "login" & "password"
        COOKIE=$(echo "$DETAILS" | parse '^cookie=' '=\([[:alnum:]]\+\)') || return

        # Unix/POSIX time
        CUR_DATE=$(echo "$DETAILS" | parse '^servertime=' '=\([[:digit:]]\+\)') || return
        END_DATE=$(echo "$DETAILS" | parse '^billeduntil' '=\([[:digit:]]\+\)') || return
        if (( END_DATE > CUR_DATE )); then
            log_debug "premium account detected"
            IS_PREMIUM=1
        fi

        PAGE=$(curl -d 'sub=download' -d "cookie=$COOKIE" \
            -d "fileid=$FILEID" -d "filename=$FILENAME" \
            "$BASE_URL") || return
    else
        PAGE=$(curl -d 'sub=download' \
            -d "fileid=$FILEID" -d "filename=$FILENAME" \
            "$BASE_URL") || return
    fi

    ERROR=$(echo "$PAGE" | parse_quiet 'ERROR:' 'ERROR:[[:space:]]*\(.*\)')

    if match 'need to wait' "$ERROR"; then
        WAIT=$(echo "$ERROR" | parse '.' 'wait \([[:digit:]]\+\) seconds') || return
        log_debug "Server has asked to wait $WAIT seconds"
        echo $((WAIT))
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif matchi 'File \(deleted\|not found\|ID invalid\|is marked as illegal\)' "$ERROR"; then
        log_debug "website error: $ERROR"
        return $ERR_LINK_DEAD

    elif match 'flooding' "$ERROR"; then
        log_debug "Server said we are flooding it."
        echo 360
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match 'slots' "$ERROR"; then
        log_debug "Server said there is no free slots available"
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif matchi 'Login failed' "$ERROR"; then
        return $ERR_LOGIN_FAILED

    # RapidPro expired. (34fa3175)
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

    wait $((WTIME)) seconds || return

    BASE_URL="//$RSHOST/cgi-bin/rsapi.cgi?sub=download&fileid=$FILEID&filename=$FILENAME&dlauth=$DLAUTH"
    if test "$AUTH"; then
        # SSL downloads (https) are only available for RapidPro customers
        if [ $IS_PREMIUM -ne 0 ]; then
            MODULE_RAPIDSHARE_DOWNLOAD_RESUME=yes
            echo "https:$BASE_URL&cookie=$COOKIE"
        else
            echo "http:$BASE_URL&cookie=$COOKIE"
        fi
    else
        echo "http:$BASE_URL"
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

    local FILE=$2
    local DESTFILE=$3
    local USER PASSWORD SERVER_NUM UPLOAD_URL INFO ERROR

    test "$AUTH" || return $ERR_LINK_NEED_PERMISSIONS

    split_auth "$AUTH" USER PASSWORD || return

    SERVER_NUM=$(curl 'http://api.rapidshare.com/cgi-bin/rsapi.cgi?sub=nextuploadserver') || return
    log_debug "upload server is rs$SERVER_NUM"

    UPLOAD_URL="https://rs${SERVER_NUM}.rapidshare.com/cgi-bin/rsapi.cgi"

    INFO=$(curl_with_log -F "sub=upload" \
        -F "filecontent=@$FILE;filename=$DESTFILE" \
        -F "login=$USER" -F "password=$PASSWORD" "$UPLOAD_URL") || return

    if ! match '^COMPLETE' "$INFO"; then
        ERROR=$(echo "$INFO" | parse_quiet "ERROR:" "ERROR:[[:space:]]*\(.*\)")
        log_error "upload failed: $ERROR"
        return $ERR_FATAL
    fi

    # Expected answer:
    # fileid,filename,filesize,md5hex
    IFS="," read FILEID FILENAME SZ <<< "${INFO:9}"

    echo "http://rapidshare.com/files/${FILEID}/$FILENAME"
}

# Delete a file on rapidshare
# $1: cookie file (unused here)
# $2: rapidshare (download) link
rapidshare_delete() {
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_DELETE_OPTIONS" "$@")"

    local URL=$2
    local USER PASSWORD FILEID RESPONSE

    test "$AUTH" || return $ERR_LINK_NEED_PERMISSIONS

    split_auth "$AUTH" USER PASSWORD || return

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

    return 0
}
