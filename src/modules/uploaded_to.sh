#!/bin/bash
#
# uploaded.to module
# Copyright (c) 2011-2012 Plowshare team
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

MODULE_UPLOADED_TO_REGEXP_URL="http://\(www\.\)\?\(uploaded\.\(to\|net\)\|ul\.to\)/"

MODULE_UPLOADED_TO_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_UPLOADED_TO_DOWNLOAD_RESUME=no
MODULE_UPLOADED_TO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_UPLOADED_TO_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)
DESCRIPTION,d,description,S=DESCRIPTION,Set file description"
MODULE_UPLOADED_TO_UPLOAD_REMOTE_SUPPORT=no

MODULE_UPLOADED_TO_DELETE_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)"
MODULE_UPLOADED_TO_LIST_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
uploaded_to_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE ERR TYPE ID NAME

    LOGIN_DATA='id=$USER&pw=$PASSWORD'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/io/login") || return

    # Note: Cookies "login" + "auth" get set on successful login
    ERR=$(echo "$PAGE" | parse_json_quiet err)

    if [ -n "$ERR" ]; then
        log_error "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    # Note: Login changes site's language according to account's preference
    uploaded_to_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    # Determine account type
    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/me") || return
    ID=$(echo "$PAGE" | parse 'ID:' '<em.*>\(.*\)</em>' 1) || return
    NAME=$(echo "$PAGE" | parse 'Alias:' '<b><b>\(.*\)</b></b>' 1) || return
    TYPE=$(echo "$PAGE" | parse 'Status:' '<em>\(.*\)</em>' 1) || return

    if [ "$TYPE" = 'Free' ]; then
        TYPE='free'
    elif [ "$TYPE" = 'Premium' ]; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    log_debug "Successfully logged in as $TYPE member '$ID' ($NAME)"
    echo "$TYPE"
}

# Switch language to english
# $1: cookie file
# $2: base URL
uploaded_to_switch_lang() {
    # Note: Language is associated with session, no new cookie is set
    curl -b "$1" -o /dev/null "$2/language/en" || return
}

# Simple and limited parsing of flawed JSON
#
# Notes:
# - Large parts copied from "parse_json" in core.sh (look there for further documentation)
# - Also accepts flawed JSON (unquoted or single quoted names/strings)
#
# $1: variable name (string)
# $2: (optional) preprocess option. Accepted values are:
#     - "join": make a single line of input stream.
#     - "split": split input buffer on comma character (,).
# stdin: JSON data
# stdout: result
uploaded_to_parse_json_alt() {
    local -r D="[\"']\?" # string/name delimiter
    local -r S="^.*$D$1$D[[:space:]]*:[[:space:]]*" # start of JSON string
    local -r E='\([,}[:space:]].*\)\?$' # end of JSON string
    local STRING PRE

    if [ "$2" = 'join' ]; then
        PRE="tr -d '\n\r' |"
    elif [ "$2" = 'split' ]; then
        PRE="sed -e 's/,[[:space:]]*/\n/g' |"
    fi

    STRING=$($PRE sed -n \
        -e "s/$S\(-\?\(0\|[1-9][[:digit:]]*\)\(\.[[:digit:]]\+\)\?\([eE][-+]\?[[:digit:]]\+\)\?\)$E/\1/p" \
        -e "s/$S\(true\|false\|null\)$E/\1/p" \
        -e "s/\\\\\"/\\\\q/g; s/$S$D\([^,}[:space:]\"']*\)$D$E/\1/p")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (json): \"$1\""
        return $ERR_FATAL
    fi

    # Translate two-character sequence escape representations
    STRING=${STRING//\\q/\"}
    STRING=${STRING//\\\\/\\}
    STRING=${STRING//\\\//\/}
    STRING=${STRING//\\b/$'\b'}
    STRING=${STRING//\\f/$'\f'}
    STRING=${STRING//\\n/$'\n'}
    STRING=${STRING//\\r/$'\r'}
    STRING=${STRING//\\t/	}

    echo "$STRING"
}

# Output an Uploaded.to file download URL
# $1: cookie file
# $2: upload.to url
# stdout: real file download link
uploaded_to_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://uploaded.net'
    local URL ACCOUNT PAGE JSON WAIT ERR FILE_ID FILE_NAME FILE_URL

    # Uploaded.to redirects all possible urls of a file to the canonical one
    # Note: There can be multiple redirections before the final one
    URL=$(curl -I -L "$2" | grep_http_header_location_quiet | last_line) || return
    [ -n "$URL" ] || URL=$2

    # Recognize folders
    if match "$BASE_URL/folder/" "$URL"; then
        log_error 'This is a directory list'
        return $ERR_FATAL
    fi

    # Page not found
    # The requested file isn't available anymore!
    if match "$BASE_URL/\(404\|410\)" "$URL"; then
        return $ERR_LINK_DEAD
    fi

    [ -n "$CHECK_LINK" ] && return 0

    uploaded_to_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    # Note: File owner never needs password and only owner may access private
    # files, so login comes first.
    if [ -n "$AUTH" ]; then
        ACCOUNT=$(uploaded_to_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Note: Save HTTP headers to catch premium users' "direct downloads"
    PAGE=$(curl -i -b "$COOKIE_FILE" "$URL") || return

    # Check for files that need a password
    if match '<h2>Authentification</h2>' "$PAGE"; then
        log_debug 'File is password protected'

        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        # Note: Again, consider "direct downloads"
        PAGE=$(curl -i -b "$COOKIE_FILE" -F "pw=$LINK_PASSWORD" "$URL") || return

        if match '<h2>Authentification</h2>' "$PAGE"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        fi
    fi

    if [ "$ACCOUNT" = "premium" ]; then
        # Premium users can resume downloads
        MODULE_UPLOADED_TO_DOWNLOAD_RESUME=yes

        # Get download link, if this was a direct download
        FILE_URL=$(echo "$PAGE" | grep_http_header_location_quiet)

        if [ -z "$FILE_URL" ]; then
            FILE_URL=$(echo "$PAGE" | parse_attr 'stor' 'action') || return
        fi

        FILE_NAME=$(curl -I -b "$COOKIE_FILE" "$FILE_URL" | \
            grep_http_header_content_disposition) || return

        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0
    fi

    if match '^[[:space:]]*var free_enabled = false;' "$PAGE"; then
        log_error 'No free download slots available'
        echo 300 # wait some arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Extract the raw file ID
    FILE_ID=$(echo "$URL" | parse . '/file/\([^/]*\)') || return

    # Request download (use dummy "-d" to force a POST request)
    JSON=$(curl -b "$COOKIE_FILE" --referer "$URL" \
        -H 'X-Requested-With: XMLHttpRequest' -d '' \
        "$BASE_URL/io/ticket/slot/$FILE_ID") || return

    if [ "$JSON" != '{succ:true}' ]; then
        ERR=$(echo "$JSON" | parse_json_quiet 'err')

        # from 'http://uploaded.to/js/download.js' - 'function(limit)'
        if [ "$ERR" = 'limit-dl' ]; then
            log_error 'Free download limit reached'
            echo 600 # wait some arbitrary time
            return $ERR_LINK_TEMP_UNAVAILABLE

        elif [ "$ERR" = 'limit-parallel' ]; then
            log_error 'No parallel download allowed.'
            echo 600 # wait some arbitrary time
            return $ERR_LINK_TEMP_UNAVAILABLE

        elif [ "$ERR" = 'limit-size' ]; then
            return $ERR_SIZE_LIMIT_EXCEEDED

        elif [ "$ERR" = 'limit-slot' ]; then
            log_error 'No free download slots available'
            echo 300 # wait some arbitrary time
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    # <span>Current waiting period: <span>30</span> seconds</span>
    WAIT=$(echo "$PAGE" | parse '<span>Current waiting period' \
        'period: <span>\([[:digit:]]\+\)</span>') || return
    wait $((WAIT + 1)) || return

    # from 'http://uploaded.to/js/download.js' - 'Recaptcha.create'
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6Lcqz78SAAAAAPgsTYF3UlGf2QFQCNuPMenuyHF3'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    JSON=$(curl -b "$COOKIE_FILE" --referer "$URL" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        "$BASE_URL/io/ticket/captcha/$FILE_ID") || return

    ERR=$(echo "$JSON" | parse_json_quiet 'err')

    if [ -n "$ERR" ]; then
        if [ "$ERR" = 'captcha' ]; then
            log_error 'Captcha wrong'
            captcha_nack "$ID"
            return $ERR_CAPTCHA
        fi

        captcha_ack "$ID"

        # You have reached the max. number of possible free downloads for this hour
        if match 'possible free downloads for this hour' "$ERR"; then
            log_error 'Hourly limit reached.'
            echo 3600
            return $ERR_LINK_TEMP_UNAVAILABLE

        # This file exceeds the max. filesize which can be downloaded by free users.
        elif match 'exceeds the max. filesize' "$ERR"; then
            return $ERR_SIZE_LIMIT_EXCEEDED

        # We\'re sorry but all of our available download slots are busy currently
        elif match 'all of our available download slots are busy' "$ERR"; then
            log_error 'No free download slots available'
            echo 300 # wait some arbitrary time
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    captcha_ack "$ID"

    # {type:'download',url:'http://storXXXX.uploaded.to/dl/...'}
    # Note: This is no valid JSON due to the unquoted/single quoted strings
    FILE_URL=$(echo "$JSON" | uploaded_to_parse_json_alt 'url') || return
    FILE_NAME=$(curl "$BASE_URL/file/$FILE_ID/status" | first_line) || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to uploaded.to
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: ul.to download link
uploaded_to_upload() {
    local -r COOKIEFILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://uploaded.net'

    local JS SERVER DATA FILE_ID AUTH_DATA ADMIN_CODE

    test "$AUTH" || return $ERR_LINK_NEED_PERMISSIONS

    JS=$(curl "$BASE_URL/js/script.js") || return
    SERVER=$(echo "$JS" | parse '//stor' "[[:space:]]'\([^']*\)") || return

    log_debug "uploadServer: $SERVER"

    uploaded_to_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return
    AUTH_DATA=$(parse_cookie 'login' < "$COOKIEFILE" | uri_decode) || return

    # TODO: Allow changing admin code (used for deletion)
    ADMIN_CODE=$(random a 8)

    DATA=$(curl_with_log --user-agent 'Shockwave Flash' \
        -F "Filename=$DESTFILE" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        -F 'Upload=Submit Query' \
        "${SERVER}upload?admincode=${ADMIN_CODE}$AUTH_DATA") || return
    FILE_ID="${DATA%%,*}"

    if [ -n "$DESCRIPTION" ]; then
        DATA=$(curl -b "$COOKIEFILE" --referer "$BASE_URL/manage" \
        --form-string "description=$DESCRIPTION" \
        "$BASE_URL/file/$FILE_ID/edit/description") || return
        log_debug "description set to: $DATA"
    fi

    echo "http://ul.to/$FILE_ID"
    echo
    echo "$ADMIN_CODE"
}

# Delete a file on uploaded.to
# $1: cookie file
# $2: uploaded.to (download) link
uploaded_to_delete() {
    local COOKIE_FILE=$1
    local URL=$2
    local BASE_URL='http://uploaded.to'
    local PAGE FILE_ID

    test "$AUTH" || return $ERR_LINK_NEED_PERMISSIONS

    # extract the raw file id
    PAGE=$(curl -L "$URL") || return

    # <h1>Page not found<br /><small class="cL">Error: 404</small></h1>
    if match "Error: 404" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_ID=$(echo "$PAGE" | parse 'file/' 'file/\([^/"]\+\)') || return
    log_debug "file id=$FILE_ID"

    uploaded_to_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/file/$FILE_ID/delete") || return

    # {succ:true}
    # Note: This is not JSON because succ is not quoted (")
    match 'true' "$PAGE" || return $ERR_FATAL
}

# List an uploaded.to shared file folder URL
# $1: uploaded.to url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
uploaded_to_list() {
    local URL=$1
    local PAGE LINKS NAMES

    # check whether it looks like a folder link
    if ! match "${MODULE_UPLOADED_TO_REGEXP_URL}folder/" "$URL"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    test "$2" && log_debug "recursive folder does not exist in depositfiles"

    PAGE=$(curl -L "$URL") || return

    LINKS=$(echo "$PAGE" | parse_all_attr 'tr id="' id)
    NAMES=$(echo "$PAGE" | parse_all_tag_quiet 'onclick="visit($(this))' a)

    test "$LINKS" || return $ERR_LINK_DEAD

    list_submit "$LINKS" "$NAMES" 'http://uploaded.to/file/' || return
}
