# Plowshare rapidshare.com module
# Copyright (c) 2010-2014 Plowshare team
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

MODULE_RAPIDSHARE_REGEXP_URL='https\?://\(www\.\|rs[[:digit:]][0-9a-z]*\.\)\?rapidshare\.com/'

MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_RAPIDSHARE_DOWNLOAD_RESUME=no
MODULE_RAPIDSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_RAPIDSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_RAPIDSHARE_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)"
MODULE_RAPIDSHARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_RAPIDSHARE_DELETE_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)"

MODULE_RAPIDSHARE_PROBE_OPTIONS=""

# Static function. Parse/Retrieve file ID and file name.
# $1: URL
# $2: base URL
# $3: variable name (file ID)
# $4: variable name (file name)
rapidshare_parse_url() {
    local -r URL=$1
    local -r BASE_URL=$2
    local I N

    # Sanity checks left out for the sake of performance!
    unset -v "$3" "$4"

    # URL format:
    # http://rapidshare.com/share/F82248B8748BECE0A9A78038E7717EE0
    #
    # And two deprecated versions:
    #  http://rapidshare.com/files/429795114/arc02f.rar
    #  http://rapidshare.com/#!download|774tl4|429794114|arc02f.rar|5249
    if [[ "$URL" = */share/* ]]; then
        # Only consider most basic shares, i.e. a single file
        local -r SHARE_ID=${URL##*/share/}
        local PAGE

        PAGE=$(curl -d 'sub=sharelinkcontent' -d "share=$SHARE_ID" \
            "$BASE_URL") || return

        if [[ "$PAGE" = ERROR* ]]; then
            [[ "$PAGE" = *'not found'* ]] && return $ERR_LINK_DEAD

            log_error "Remote error: ${PAGE#ERROR: }"
            return $ERR_FATAL
        fi

        eval $3=\$\(cut -d\',\' -f1 \<\<\< \"\${PAGE#file:}\"\)
        eval $4=\$\(cut -d\',\' -f2 \<\<\< \"\${PAGE#file:}\"\)
    elif [[ "$URL" = *'/#!download|'* ]]; then
        eval $3=\$\(cut -d\'\|\' -f3 \<\<\< \"\$URL\"\)
        eval $4=\$\(cut -d\'\|\' -f4 \<\<\< \"\$URL\"\)
    else
        eval $3=\$\(cut -d\'/\' -f5 \<\<\< \"\$URL\"\)
        eval $4=\$\(cut -d\'/\' -f6 \<\<\< \"\$URL\"\)
    fi

    if [ -z "${!3}" -o -z "${!4}" ]; then
        log_error "Cannot parse file ID/filename from URL: $URL"
        return $ERR_FATAL
    fi
}

# Output a rapidshare file download URL
# $1: cookie file (unused here)
# $2: rapidshare.com url
# stdout: real file download link
rapidshare_download() {
    local BASE_URL='https://api.rapidshare.com/cgi-bin/rsapi.cgi'
    local FILEID FILENAME USER PASSWORD COOKIE PAGE ERROR WAIT
    local IS_PREMIUM=0

    rapidshare_parse_url "$2" "$BASE_URL" FILEID FILENAME || return

    if test "$AUTH"; then
        local DETAILS CUR_DATE END_DATE

        split_auth "$AUTH" USER PASSWORD || return
        USER=$(echo "$USER" | uri_encode_strict)
        PASSWORD=$(echo "$PASSWORD" | uri_encode_strict)

        DETAILS=$(curl -d 'sub=getaccountdetails' \
            -d "login=$USER" -d "password=$PASSWORD" \
            -d 'withcookie=1' -d 'withpublicid=0' \
            "$BASE_URL") || return

        # ERROR: Login failed. Password incorrect or account not found.
        if match 'Login failed' "$DETAILS"; then
            return $ERR_LOGIN_FAILED
        elif match '^ERROR' "$DETAILS"; then
            log_error "Remote error: ${DETAILS#ERROR: }"
            return $ERR_FATAL
        fi

        # "cookie" parameter overrides "login" & "password"
        COOKIE=$(echo "$DETAILS" | parse '^cookie=' '=\([[:alnum:]]\+\)') || return

        # Unix/POSIX time
        CUR_DATE=$(echo "$DETAILS" | parse '^servertime=' '=\([[:digit:]]\+\)') || return
        END_DATE=$(echo "$DETAILS" | parse '^billeduntil' '=\([[:digit:]]\+\)') || return
        if (( END_DATE > CUR_DATE )); then
            log_debug 'Premium account detected'
            IS_PREMIUM=1
        fi

        PAGE=$(curl -d 'sub=download' -d "cookie=$COOKIE" \
            -d "fileid=$FILEID" --data-urlencode "filename=$FILENAME" \
            "$BASE_URL") || return
    else
        PAGE=$(curl -d 'sub=download' -d "fileid=$FILEID" \
            --data-urlencode "filename=$FILENAME" "$BASE_URL") || return
    fi

    ERROR=$(echo "$PAGE" | parse_quiet 'ERROR:' 'ERROR:[[:space:]]*\(.*\)')

    if [ -n "$ERROR" ]; then
        if match 'need to wait' "$ERROR"; then
            WAIT=$(echo "$ERROR" | parse '.' 'wait \([[:digit:]]\+\) seconds') || return
            log_debug "Server has asked to wait $WAIT seconds."
            echo $((WAIT))
            return $ERR_LINK_TEMP_UNAVAILABLE

        elif matchi 'Filename invalid' "$ERROR"; then
            log_debug "Remote error: $ERROR"
            return $ERR_LINK_DEAD

        elif matchi 'File \(deleted\|not found\|ID invalid\|is marked as illegal\)' "$ERROR"; then
            log_debug "Remote error: $ERROR"
            return $ERR_LINK_DEAD

        elif match 'flooding' "$ERROR"; then
            log_debug 'Server said we are flooding it.'
            echo 360
            return $ERR_LINK_TEMP_UNAVAILABLE

        elif match 'slots' "$ERROR"; then
            log_debug 'Server said there is no free slots available.'
            return $ERR_LINK_TEMP_UNAVAILABLE

        elif matchi 'Login failed' "$ERROR"; then
            return $ERR_LOGIN_FAILED

        # You need RapidPro to download more files from your IP address. (8d5611a9)
        elif match 'download more files from your IP address' "$ERROR"; then
            log_error 'No parallel download allowed.'
            echo 120 # wait some arbitrary time
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        # RapidPro expired. (34fa3175)
        log_error "Remote error: $ERROR"
        return $ERR_FATAL
    fi

    # DL:$hostname,$dlauth,$countdown,$md5hex
    IFS=',' read RSHOST DLAUTH WTIME CRC <<< "${PAGE#DL:}"

    if [ -z "$RSHOST" -o -z "$DLAUTH" -o -z "$WTIME" -o -z "$CRC" ]; then
        log_error 'Unexpected page content'
        return $ERR_FATAL
    fi

    log_debug "File MD5: $CRC"

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
    uri_decode <<< "$FILENAME"
}

# Upload a file to rapidshare using rsapi - http://images.rapidshare.com/apidoc.txt
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download_url
rapidshare_upload() {
    local FILE=$2
    local DESTFILE=$3
    local USER PASSWORD SERVER_NUM UPLOAD_URL INFO ERROR

    test "$AUTH" || return $ERR_LINK_NEED_PERMISSIONS

    split_auth "$AUTH" USER PASSWORD || return

    SERVER_NUM=$(curl 'http://api.rapidshare.com/cgi-bin/rsapi.cgi?sub=nextuploadserver') || return
    log_debug "upload server is rs$SERVER_NUM"

    UPLOAD_URL="https://rs${SERVER_NUM}.rapidshare.com/cgi-bin/rsapi.cgi"

    local SZ=$(get_filesize "$FILE")
    local -r MAX_SIZE=2147483648 # 2GiB
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    INFO=$(curl_with_log -F 'sub=upload' \
        -F "filecontent=@$FILE;filename=$DESTFILE" \
        -F "login=$USER" -F "password=$PASSWORD" "$UPLOAD_URL") || return

    if ! match '^COMPLETE' "$INFO"; then
        ERROR=$(echo "$INFO" | parse_quiet 'ERROR:' 'ERROR:[[:space:]]*\(.*\)')
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
        log_error 'cannot parse fileid from URL'
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

# Probe a download URL
# $1: cookie file (unused here)
# $2: Rapidshare url
# $3: requested capability list
# stdout: 1 capability per line
rapidshare_probe() {
    local -r REQ_IN=$3
    local BASE_URL='https://api.rapidshare.com/cgi-bin/rsapi.cgi'
    local RESPONSE REQ_OUT FILE_ID FILE_NAME FILE_SIZE FILE_HASH STATUS DUMMY

    rapidshare_parse_url "$2" "$BASE_URL" FILE_ID FILE_NAME || return

    RESPONSE=$(curl -d 'sub=checkfiles' -d "files=$FILE_ID" \
        --data-urlencode "filenames=$FILE_NAME" "$BASE_URL") || return

    # ERROR: File not found.
    if [[ "$RESPONSE" = ERROR:\ * ]]; then
        log_error "Unexpected remote error: ${RESPONSE#ERROR: }"
        return $ERR_FATAL
    fi

    # file ID, filename, size, server ID, status, short host, MD5
    IFS=',' read DUMMY FILE_NAME FILE_SIZE DUMMY STATUS DUMMY FILE_HASH <<< "$RESPONSE"

    [ "$STATUS" -eq 1 ] || return $ERR_LINK_DEAD
    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        [ -n "$FILE_NAME" ] && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        [ -n "$FILE_SIZE" ] && echo "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *h* ]]; then
        [ -n "$FILE_HASH" ] && echo "$FILE_HASH" && REQ_OUT="${REQ_OUT}h"
    fi

    echo $REQ_OUT
}
