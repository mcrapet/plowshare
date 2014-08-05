# Plowshare euroshare.eu module
# Copyright (c) 2011 halfman <Pulpan3@gmail.com>
# Copyright (c) 2012-2013 Plowshare team
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

MODULE_EUROSHARE_EU_REGEXP_URL='http://\(www\.\)\?euroshare\.eu/'

MODULE_EUROSHARE_EU_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_EUROSHARE_EU_DOWNLOAD_RESUME=no
MODULE_EUROSHARE_EU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_EUROSHARE_EU_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_EUROSHARE_EU_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
DESCRIPTION,d,description,S=DESCRIPTION,Set file description"
MODULE_EUROSHARE_EU_UPLOAD_REMOTE_SUPPORT=no

MODULE_EUROSHARE_EU_DELETE_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account (mandatory)"

MODULE_EUROSHARE_EU_PROBE_OPTIONS=""

# Static function. Proceed with login (free)
# $1: authentication
# $2: cookie file
# $3: base url
euroshare_eu_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE EMAIL

    LOGIN_DATA='login=$USER&password=$PASSWORD+&trvale=1'
    PAGE=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/customer-zone/login/" -L) || return

    # <p>Boli ste úspešne prihlásený</p>
    match 'Boli ste úspešne prihlásený' "$PAGE" || return $ERR_LOGIN_FAILED

    # <li><a href="/customer-zone/logout/" title="Odhlásiť">Odhlásiť (xyz)</a></li>
    EMAIL=$(echo "$PAGE" | parse 'Odhlásiť' 'Odhlásiť (\([^)]\+\))') || return

    log_debug "Successfully logged in as member '$EMAIL'"
}

# Output a Euroshare.eu file download URL
# $1: cookie file
# $2: euroshare.eu url
# stdout: real file download link
#         file name
euroshare_eu_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.euroshare.eu'
    local PAGE DL_URL FILE_NAME

    # HTML returned uses UTF-8 charset
    PAGE=$(curl -c "$COOKI_FILE" "$URL") || return

    match 'Soubor nenalezen</h1>' "$PAGE" && return $ERR_LINK_DEAD

    if [ -n "$AUTH_FREE" ]; then
        euroshare_eu_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

    # <a href="http://s2.euroshare.eu:90/_/free.php?fid=xxx" class="tlacitko modry velky">STIAHNUŤ SÚBOR FREE</a>
    DL_URL=$(echo "$PAGE" | parse_attr 'tlacitko modry velk' href) || return

    FILE_NAME=$(echo "$PAGE" | parse_tag '"nazev-souboru"' h1)
    FILE_NAME=${FILE_NAME% (*}

    echo "$DL_URL"
    echo "$FILE_NAME"
}

# Upload a file to Euroshare.eu
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
euroshare_eu_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://euroshare.eu'
    local -r MAX_SIZE=1610612736 # 1.5GiB
    local PAGE SIZE UPLOAD_URL USER_ID FORM_PLAIN

    if [ -n "$AUTH_FREE" ]; then
        euroshare_eu_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL")

    # SWFUpload
    UPLOAD_URL=$(echo "$PAGE" | parse 'upload_url' ':[[:space:]]*"\([^"]*\)') || return
    USER_ID=$(echo "$PAGE" | parse 'post_params' "uID.[[:space:]]*:[[:space:]]*'\([^']*\)") || return
    FORM_PLAIN=$(echo "$PAGE" | parse 'post_params' "plain.[[:space:]]*:[[:space:]]*\([^}]*\)") || return

    PAGE=$(curl_with_log --user-agent 'Shockwave Flash' \
        -F "uID=$USER_ID" \
        -F "plain=$FORM_PLAIN" \
        -F "Filename=$DEST_FILE" \
        --form-string "popis1=$DESCRIPTION" \
        -F 'soukromy1=0' \
        -F "soubor1=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        -F 'Upload=Submit Query' \
        "$UPLOAD_URL") || return

    echo "${PAGE%|*}"
    echo "${PAGE#*|}"
}

# Delete a file from Euroshare.eu
# $1: cookie file (unused here)
# $2: euroshare.eu (delete) link
euroshare_eu_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.euroshare.eu'
    local PAGE FILE_ID

    PAGE=$(curl "$URL") || return

    match 'Soubor nenalezen</h1>' "$PAGE" && return $ERR_LINK_DEAD

    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS

    # Note: Deletion page does not work, so we use the file manager instead
    FILE_ID=$(echo "$URL" | \
        parse_quiet . '/delete/[[:alnum:]]\+/\([[:digit:]]\+\)/')

    if [ -z "$FILE_ID" ]; then
        log_error 'This is not a delete link.'
        return $ERR_FATAL
    fi
    log_debug "File ID: '$FILE_ID'"

    euroshare_eu_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    PAGE=$(curl -b "$COOKIE_FILE" -H 'X-Requested-With: XMLHttpRequest' \
        -d "id=item_$FILE_ID" \
        "$BASE_URL/ajax/file-manager/file-remove/") || return

    if ! match 'Array' "$PAGE"; then
        log_error 'Could not delete file. Site updated?'
        return $ERR_FATAL
    fi
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: zippyshare url
# $3: requested capability list
# stdout: 1 capability per line
euroshare_eu_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local JSON FILE_NAME FILE_SIZE FILE_HASH REQ_OUT

    # Official API: http://euroshare.eu/euroshare-api/
    JSON=$(curl --get -d 'sub=checkfile' -d "file=$URL" -d "file_password=" \
        'http://euroshare.eu/euroshare-api/') || return

    # ERR: File does not exists.
    match '^ERR:' "$JSON" && return $ERR_LINK_DEAD

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(echo "$JSON" | parse_json 'file_name') && \
            echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$JSON" | parse_json 'file_size') && \
            echo "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *h* ]]; then
        FILE_HASH=$(echo "$JSON" | parse_json 'md5_hash') && \
            echo "$FILE_HASH" && REQ_OUT="${REQ_OUT}h"
    fi

    echo $REQ_OUT
}
