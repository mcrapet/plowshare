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
AUTH_PREMIUMZONE,a:,auth:,USER:PASSWORD,Use Premium-Zone account
AUTH_FREEZONE,b:,auth-freezone:,USER:PASSWORD,Use Free-Zone account"
MODULE_RAPIDSHARE_DELETE_OPTIONS=""

# Output a rapidshare file download URL (anonymous and premium)
# $1: cookie file (unused here)
# $2: rapidshare.com url
# stdout: real file download link
rapidshare_download() {
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS" "$@")"
    URL="$2"

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
    test "$FILEID" -a "$FILENAME" ||
        { log_error "Cannot parse fileID/filename from URL: $URL"; return 1; }

    # Arbitrary wait (local variables)
    NO_FREE_SLOT_IDLE=125
    STOP_FLOODING=360

    while retry_limit_not_reached || return 3; do
        BASE_APIURL="https://api.rapidshare.com/cgi-bin/rsapi.cgi?sub=download_v1&fileid=${FILEID}&filename=${FILENAME}"

        if test "$AUTH"; then
            IFS=":" read USER PASSWORD <<< "$AUTH"
            PARAMS="&login=$USER&password=$PASSWORD"
        else
            PARAMS=""
        fi
        PAGE=$(curl "${BASE_APIURL}${PARAMS}") ||
            { log_error "cannot get main API page"; return 1; }

        ERROR=$(echo "$PAGE" | parse_quiet "ERROR:" "ERROR:[[:space:]]*\(.*\)")
        test "$ERROR" && log_debug "website error: $ERROR"

        if match "need to wait" "$ERROR"; then
            WAIT=$(echo "$ERROR" | parse "." "wait \([[:digit:]]\+\) seconds") ||
                { log_error "cannot parse wait time: $ERROR"; return 1; }
            test "$CHECK_LINK" && return 0
            log_notice "Server has asked to wait $WAIT seconds"
            wait $WAIT seconds || return 2
            continue

        elif match "File \(deleted\|not found\|ID invalid\)" "$ERROR"; then
            return 254

        elif match "flooding" "$ERROR"; then
            no_arbitrary_wait || return 253
            log_debug "Server said we are flooding it."
            wait $STOP_FLOODING seconds || return 2
            continue

        elif match "slots" "$ERROR"; then
            no_arbitrary_wait || return 253
            log_debug "Server said there is no free slots available"
            wait $NO_FREE_SLOT_IDLE seconds || return 2
            continue

        elif test "$ERROR"; then
            log_error "website error: $ERROR"
            return 1
        fi

        PAGE=$(echo "$PAGE" | parse 'DL' 'DL:\(.*\)') || {
            log_error "unexpected page content";
            return 1;
        }

        local RSHOST=$(echo "$PAGE" | cut -d',' -f1)
        local DLAUTH=$(echo "$PAGE" | cut -d',' -f2)
        local WTIME=$(echo "$PAGE" | cut -d',' -f3)

        test "$CHECK_LINK" && return 0
        break
    done

    wait $((WTIME)) seconds || return 2

    # https is only available for RapidPro customers
    local BASEURL="http://$RSHOST/cgi-bin/rsapi.cgi?sub=download_v1"

    if test "$AUTH"; then
        echo "$BASEURL&fileid=$FILEID&filename=$FILENAME&login=$USER&password=$PASSWORD"
    else
        echo "$BASEURL&fileid=$FILEID&filename=$FILENAME&dlauth=$DLAUTH"
    fi
    echo "$FILENAME"
}

# Upload a file to rapidshare using rsapi - http://images.rapidshare.com/apidoc.txt
# $1: file name to upload
# $2: upload as file name (optional, defaults to $1)
# stdout: download_url (delete_url)
rapidshare_upload() {
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"

    if test -n "$AUTH_PREMIUMZONE"; then
        log_debug "premium download not available"
    elif test -n "$AUTH_FREEZONE"; then
        log_debug "freezone download not available"
    else
        rapidshare_upload_anonymous "$@"
    fi
}

# Upload a file to rapidshare (anonymously)
# $1: file name to upload
# $2: upload as file name (optional, defaults to $1)
# stdout: download_url (delete_url)
rapidshare_upload_anonymous() {
    FILE="$1"
    DESTFILE=${2:-$FILE}

    SERVER_NUM=$(curl "http://api.rapidshare.com/cgi-bin/rsapi.cgi?sub=nextuploadserver")
    log_debug "free upload server is rs$SERVER_NUM"

    UPLOAD_URL="https://rs${SERVER_NUM}.rapidshare.com/cgi-bin/upload.cgi"

    INFO=$(curl_with_log -F "filecontent=@$FILE;filename=$(basename_file "$DESTFILE")" \
            -F "rsapi_v1=1" -F "realfolder=0" "$UPLOAD_URL") || return 1

    # Expect answer like this (.3 is filesize, .4 is md5sum):
    # savedfiles=1 forbiddenfiles=0 premiumaccount=0
    # File1.1=http://rapidshare.com/files/425566082/RFC-all.tar.gz
    # File1.2=http://rapidshare.com/files/425566082/RFC-all.tar.gz?killcode=17632915428441196428
    # File1.3=225280
    # File1.4=0902CFBAF085A18EC47B252364BDE491
    # File1.5=Completed

    URL=$(echo "$INFO" | parse "files" "1=\(.*\)") || return 1
    KILL=$(echo "$INFO" | parse "killcode" "2=\(.*\)") || return 1

    echo "$URL ($KILL)"
}

# Delete a file on rapidshare
# $1: delete link
rapidshare_delete() {
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_DELETE_OPTIONS" "$@")"
    URL="$1"

    # Two URL formats:
    # https://rapidshare.com/files/1706226814/arc02f.rar?killcode=15013892074548155797'
    # https://rapidshare.com/#!index|deletefiles|15013892074548155797|1706226814|arc02f.rar
    if match '.*/#!index|' "$URL"; then
        KILLCODE=$(echo "$URL" | cut -d'|' -f3)
        FILEID=$(echo "$URL" | cut -d'|' -f4)
    else
        KILLCODE=$(echo "$URL" | parse_quiet kill 'killcode=\(.*\)')
        FILEID=$(echo "$URL" | cut -d'/' -f5)
    fi

    if [ -z "$KILLCODE" ]; then
        log_error "cannot parse killcode from URL"
        return 1
    fi

    if [ -z "$FILEID" ]; then
        log_error "cannot parse fileid from URL"
        return 1
    fi

    log_debug "FileID=$FILEID"
    log_debug "KillCode=$KILLCODE"

    local RESPONSE=$(curl \
            "https://api.rapidshare.com/cgi-bin/rsapi.cgi?sub=deletefreefile&killcode=${KILLCODE}&fileid=${FILEID}")

    # Possible answers:
    # OK
    # ERROR: Deletion not possible. (441e3b41)
    ERROR=$(echo "$RESPONSE" | parse_quiet "ERROR:" "ERROR:[[:space:]]*\(.*\)")

    if [ -n "$ERROR" ]; then
        log_error "website error: $ERROR"
        return 1
    elif [ "$RESPONSE" != "OK" ]; then
        log_debug "unexpected result"
        return 1
    fi

    log_debug "file removed successfully"
    return 0
}
