#!/bin/bash
#
# cloudzer.net module
# Copyright (c) 2013 Plowshare team
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

MODULE_CLOUDZER_NET_REGEXP_URL='http://\(cloudzer\.net/\(file\|f\|folder\)\|clz\.to\)/'

MODULE_CLOUDZER_NET_DOWNLOAD_OPTIONS=""
MODULE_CLOUDZER_NET_DOWNLOAD_RESUME=no
MODULE_CLOUDZER_NET_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_CLOUDZER_NET_DOWNLOAD_SUCCESSIVE_INTERVAL=3600

MODULE_CLOUDZER_NET_LIST_OPTIONS=""
MODULE_CLOUDZER_NET_LIST_HAS_SUBFOLDERS=no

MODULE_CLOUDZER_NET_UPLOAD_OPTIONS="
ADMIN_CODE,,admin-code,s=ADMIN_CODE,Admin code (used for file deletion)
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)
DIRECT,,direct,,Create a direct download link
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
PRIVATE_FILE,,private,,Do not allow others to download the file"
MODULE_CLOUDZER_NET_UPLOAD_REMOTE_SUPPORT=no

MODULE_CLOUDZER_NET_DELETE_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)"

MODULE_CLOUDZER_NET_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
cloudzer_net_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE ERR TYPE USER NAME

    LOGIN_DATA='id=$USER&pw=$PASSWORD'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/io/login") || return

    # Note: Cookies "login" + "auth" get set on successful login
    # {"loc":"me"}
    ERR=$(echo "$PAGE" | parse_json_quiet err)

    if [ -n "$ERR" ]; then
        log_error "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    # Determine account type
    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/me") || return
    NAME=$(echo "$PAGE" | parse_tag_quiet 'chAlias' 'b')
    USER=$(echo "$PAGE" | parse 'chAlias' '^[[:space:]]\+\([^[:space:]]\+\)' 1)

    if match 'status_free.>Free<' "$PAGE"; then
        TYPE='free'
    elif match 'status_premium.>Premium<' "$PAGE"; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    log_debug "Successfully logged in as $TYPE member '$USER' (${NAME:-n/a})"
    echo "$TYPE"
}

# Output an cloudzer.net file download URL
# $1: cookie file
# $2: cloudzer.net url
# stdout: real file download link
cloudzer_net_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(replace '//clz.to' '//cloudzer.net/file' <<< "$2")
    local -r BASE_URL='http://cloudzer.net'
    local FILE_ID PAGE RESPONSE WAITTIME FILE_NAME FILE_URL

    PAGE=$(curl -L --cookie-jar "$COOKIE_FILE" "$URL" | \
        break_html_lines_alt) || return

    if match 'class="message error"' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi


    FILE_ID=$(echo "$PAGE" | parse_attr '"auth"' 'content') || return
    WAITTIME=$(echo "$PAGE" | parse_attr '"wait"' 'content') || return
    log_debug "FileID: '$FILE_ID'"

    if match 'No connection to database' "$PAGE"; then
        log_debug 'server error'
        echo 600 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'All of our free-download capacities are exhausted currently|The free download is currently not available' "$PAGE"; then
        log_debug 'no free download slot available'
        echo 600 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 're already downloading' "$PAGE"; then
        log_debug 'a download is already running'
        echo 600 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'Only Premiumusers are allowed to download files' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FILE_NAME=$(curl "${BASE_URL}/file/${FILE_ID}/status" | first_line) || return

    wait $((WAITTIME + 1))

    # Request captcha page
    RESPONSE=$(curl --cookie-jar "$COOKIE_FILE" \
        "${BASE_URL}/js/download.js") || return

    # Solve recaptcha
    if match 'Recaptcha.create' "$RESPONSE"; then
        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6Lcqz78SAAAAAPgsTYF3UlGf2QFQCNuPMenuyHF3'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<< "$WCI"
    else
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    # Request a download slot
    RESPONSE=$(curl -H 'X-Requested-With:XMLHttpRequest' \
        "${BASE_URL}/io/ticket/slot/$FILE_ID") || return

    # {"succ":true}
    if ! match_json_true 'succ' "$RESPONSE"; then
        log_error "Unexpected remote error: $RESPONSE"
        return $ERR_FATAL
    fi

    # Post captcha solution to webpage
    RESPONSE=$(curl --cookie "$COOKIE_FILE" \
        --data "recaptcha_challenge_field=$CHALLENGE" \
        --data "recaptcha_response_field=$WORD" \
        "${BASE_URL}/io/ticket/captcha/$FILE_ID") || return

    # Handle server (JSON) response
    if match '"captcha"' "$RESPONSE"; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'captcha_correct'

    if match '"type":"download"' "$RESPONSE"; then
        FILE_URL=$(echo "$RESPONSE" | parse_json url) || return
        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0

    elif match 'You have reached the max. number of possible free downloads for this hour' "$RESPONSE"; then
        log_debug 'you have reached the max. number of possible free downloads for this hour'
        echo 600 # arbitary time
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match 'parallel' "$RESPONSE"; then
        log_debug 'a download is already running'
        echo 600 # arbitary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}

# Upload a file to Cloudzer.net
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: clz.to download link
cloudzer_net_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://cloudzer.net'
    local -r MAX_SIZE=1073741823
    local ACCOUNT PAGE SERVER AUTH_DATA FILE_ID

    # Sanity check
    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    if [ -n "$LINK_PASSWORD" ]; then
        local -r PW_MAX=12

        if [ -n "$PRIVATE_FILE" ]; then
            log_error 'Private files cannot be password protected'
            return $ERR_BAD_COMMAND_LINE
        fi

        # Check length limitation
        if [ ${#LINK_PASSWORD} -gt $PW_MAX ]; then
            log_error "Password must not be longer than $PW_MAX characters"
            return $ERR_BAD_COMMAND_LINE
        fi
    fi

    if [ -n "$ADMIN_CODE" ]; then
        local -r AC_MAX=30
        local -r AC_FORBIDDEN="/ '\"%#;&"

        # Check length limitation
        if [ ${#ADMIN_CODE} -gt $AC_MAX ]; then
            log_error "Admin code must not be longer than $AC_MAX characters"
            return $ERR_BAD_COMMAND_LINE
        fi

        # Check for forbidden characters
        if match "[$AC_FORBIDDEN]" "$ADMIN_CODE"; then
            log_error "Admin code must not contain any of these: $AC_FORBIDDEN"
            return $ERR_BAD_COMMAND_LINE
        fi
    else
        ADMIN_CODE=$(random a 8)
    fi

    ACCOUNT=$(cloudzer_net_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return

    if [ "$ACCOUNT" != 'premium' ]; then
        local SIZE
        SIZE=$(get_filesize "$FILE") || return

        if [ $SIZE -gt $MAX_SIZE ]; then
            log_debug "File is bigger than $MAX_SIZE"
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    AUTH_DATA=$(parse_cookie 'login' < "$COOKIE_FILE" | uri_decode | \
        parse . '^\(&id=.\+&pw=.\+\)&cks=') || return

    PAGE=$(curl "$BASE_URL/js/script.js") || return
    SERVER=$(echo "$PAGE" | parse 'uploadServer =' "[[:space:]]'\([^']*\)") || return

    log_debug "Upload server: $SERVER"

    PAGE=$(curl_with_log --user-agent 'Shockwave Flash' \
        -F "Filename=$DEST_FILE" \
        -F "Filedata=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        -F 'Upload=Submit Query' \
        "${SERVER}upload?admincode=$ADMIN_CODE$AUTH_DATA") || return

    if match '<title>504 Gateway Time-out</title>' "$PAGE"; then
        log_error 'Remote server error, maybe due to overload.'
        echo 120 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # id,0
    FILE_ID="${PAGE%%,*}"

    # Do we need to edit the file? (change visibility, set password)
    if [ -n "$PRIVATE_FILE" -o -n "$LINK_PASSWORD" ]; then
        log_debug 'editing file...'
        local OPT_PRIV='true'

        [ -n "$LINK_PASSWORD" ] && OPT_PRIV=$LINK_PASSWORD

        # Note: Site uses the same API call to set file private or set a password
        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "auth=$FILE_ID" -d "priv=$OPT_PRIV" \
            "$BASE_URL/api/file/priv") || return

        if [ "$PAGE" != '{"succ":"true"}' ]; then
            log_error 'Could not set file as private. Site updated?'
        fi
    fi

    if [ -n "$DIRECT" ]; then
        log_debug 'mark file as direct download...'

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "auth=$FILE_ID" -d 'ddl=1' \
            "$BASE_URL/api/file/ddl") || return

        if [ "$PAGE" != '{"succ":"true"}' ]; then
            log_error 'Could not set file as private. Site updated?'
        fi
    fi

    echo "http://clz.to/$FILE_ID"
    echo
    echo "$ADMIN_CODE"
}

# Delete a file on Cloudzer.net
# $1: cookie file
# $2: cloudzer.net (download) link
cloudzer_net_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$(replace '//clz.to' '//cloudzer.net/file' <<< "$2")
    local -r BASE_URL='http://cloudzer.net'
    local JSON FILE_ID

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    # Recognize folders
    if match "/f\(older\)\?/" "$URL"; then
        log_error 'This is a directory list'
        return $ERR_FATAL
    fi

    cloudzer_net_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" >/dev/null || return

    FILE_ID=$(echo "$URL" | parse . 'file/\([[:alnum:]]\+\)')
    log_debug "file_id: '$FILE_ID'"

    # {succ:true} <= bad JSON, succ is not double quoted!
    # {"err":"No User"}
    JSON=$(curl -b "$COOKIE_FILE" -H 'X-Requested-With: XMLHttpRequest' \
        --referer "$URL" "$URL/delete") || return
    test "$JSON" || return $ERR_LINK_DEAD

    #match_json_true succ "$JSON" || return $ERR_FATAL
    [ "$JSON" = '{succ:true}' ] || return $ERR_FATAL
}

# List a Cloudzer.net shared file folder URL
# $1: cloudzer.net url
# $2: recurse subfolders (ignored here)
# stdout: list of links
cloudzer_net_list() {
    local URL=$1
    local PAGE LINKS NAMES

    # Check whether it looks like a folder link
    if ! match "/f\(older\)\?/" "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    PAGE=$(curl -L "$URL") || return

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'tr id="' id)
    NAMES=$(echo "$PAGE" | parse_all_tag_quiet 'onclick="visit($(this))' a)

    test "$LINKS" || return $ERR_LINK_DEAD

    list_submit "$LINKS" "$NAMES" 'http://cloudzer.net/file/'
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: cloudzer.net url
# $3: requested capability list
cloudzer_net_probe() {
    local -r URL=$(replace '//clz.to' '//cloudzer.net/file' <<< "$2")
    local -r REQ_IN=$3
    local URL FILE_ID RESPONSE FILE_NAME FILE_SIZE REQ_OUT

    FILE_ID=$(echo "$URL" | parse . 'file/\([[:alnum:]]\+\)')

    RESPONSE=$(curl "http://cloudzer.net/file/${FILE_ID}/status") || return
    { read FILE_NAME; read FILE_SIZE; } <<< "$RESPONSE"

    test -z "$RESPONSE" && return $ERR_LINK_DEAD

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        test "$FILE_NAME" && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        test "$FILE_SIZE" && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
