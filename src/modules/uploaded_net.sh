# Plowshare uploaded.net module
# Copyright (c) 2011-2014 Plowshare team
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

MODULE_UPLOADED_NET_REGEXP_URL='http://\(www\.\)\?\(uploaded\.\(to\|net\)\|ul\.to\)/'

MODULE_UPLOADED_NET_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_UPLOADED_NET_DOWNLOAD_RESUME=no
MODULE_UPLOADED_NET_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_UPLOADED_NET_DOWNLOAD_SUCCESSIVE_INTERVAL=7200

MODULE_UPLOADED_NET_UPLOAD_OPTIONS="
ADMIN_CODE,,admin-code,s=ADMIN_CODE,Admin code (used for file deletion)
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)
FOLDER,,folder,s=FOLDER,Folder to upload files into
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
PRIVATE_FILE,,private,,Do not allow others to download the file"
MODULE_UPLOADED_NET_UPLOAD_REMOTE_SUPPORT=no

MODULE_UPLOADED_NET_DELETE_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)"

MODULE_UPLOADED_NET_LIST_OPTIONS=""
MODULE_UPLOADED_NET_LIST_HAS_SUBFOLDERS=no

MODULE_UPLOADED_NET_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
uploaded_net_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE ERR TYPE ID NAME

    LOGIN_DATA='id=$USER&pw=$PASSWORD'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/io/login") || return

    # Note: Cookies "login" + "auth" get set on successful login
    ERR=$(parse_json_quiet 'err' <<< "$PAGE")

    if [ -n "$ERR" ]; then
        log_error "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    # Note: Login changes site's language according to account's preference
    uploaded_net_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    # Determine account type
    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/me") || return
    ID=$(parse 'ID:' '<em.*>\(.*\)</em>' 1 <<< "$PAGE") || return
    TYPE=$(parse 'Status:' '<em>\(.*\)</em>' 1 <<< "$PAGE") || return
    NAME=$(parse_quiet 'Alias:' '<b><b>\(.*\)</b></b>' 1 <<< "$PAGE")

    if [ "$TYPE" = 'Free' ]; then
        TYPE='free'
    elif [ "$TYPE" = 'Premium' ]; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    log_debug "Successfully logged in as $TYPE member '$ID' (${NAME:-n/a})"
    echo "$TYPE"
}

# Switch language to english
# $1: cookie file
# $2: base URL
uploaded_net_switch_lang() {
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
uploaded_net_parse_json_alt() {
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

# Check if specified folder name is valid.
# When multiple folders have the same name, first one is taken.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base URL
# stdout: folder ID
uploaded_net_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local JSON FOLDERS FOL_ID

    # Special treatment for root folder (always uses ID "0")
    if [ "$NAME" = 'root' ]; then
        echo 0
        return 0
    fi

    JSON=$(curl -b "$COOKIE_FILE" "$BASE_URL/api/folder/tree") || return

    # Find matching folder ID
    FOL_ID=$(parse_quiet . "{\"id\":\"\([[:alnum:]]\+\)\",\"name\":\"$NAME\"" <<< "$JSON")

    if [ -n "$FOL_ID" ]; then
        echo "$FOL_ID"
        return 0
    fi

    FOLDERS=$(parse_json 'name' 'split' <<< "$JSON") || return
    log_error 'Invalid folder, choose from:' $FOLDERS
    return $ERR_BAD_COMMAND_LINE
}

# Extract file ID from download link
# $1: canonical uploaded.net download URL
# $2: base URL
# stdout: file ID
uploaded_net_extract_file_id() {
    local FILE_ID

    # check whether it looks like a folder link
    if match "${MODULE_UPLOADED_NET_REGEXP_URL}f\(older\)\?/" "$URL"; then
        log_error 'This is a folder. Please use plowlist.'
        return $ERR_FATAL
    fi

    FILE_ID=$(parse . "$2/file/\([[:alnum:]]\+\)" <<< "$1") || return
    log_debug "File ID: '$FILE_ID'"
    echo "$FILE_ID"
}


# Output an Uploaded.net file download URL
# $1: cookie file
# $2: uploaded.net url
# stdout: real file download link
uploaded_net_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://uploaded.net'
    local URL ACCOUNT PAGE JSON WAIT ERR FILE_ID FILE_NAME FILE_URL

    # Uploaded.net redirects all possible urls of a file to the canonical one
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

    uploaded_net_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    # Note: File owner never needs password and only owner may access private
    # files, so login comes first.
    if [ -n "$AUTH" ]; then
        ACCOUNT=$(uploaded_net_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
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

    FILE_ID=$(uploaded_net_extract_file_id "$URL" "$BASE_URL") || return
    FILE_NAME=$(curl "$BASE_URL/file/$FILE_ID/status" | first_line) || return

    if [ "$ACCOUNT" = 'premium' ]; then
        # Premium users can resume downloads
        MODULE_UPLOADED_NET_DOWNLOAD_RESUME=yes

        # Seems that download rate is lowered..
        MODULE_UPLOADED_NET_DOWNLOAD_SUCCESSIVE_INTERVAL=30

        # Get download link, if this was a direct download
        FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

        if match 'your Hybrid-Traffic is completely exhausted' "$PAGE"; then
            WAIT=$(parse 'Hybrid-Traffic.*exhausted' \
                'will be released in \([[:digit:]]\+\) minutes' <<< "$PAGE")
            echo $(( ${WAIT:-60} * 60 ))
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        if [ -z "$FILE_URL" ]; then
            FILE_URL=$(parse_attr 'stor[[:digit:]]\+\.' 'action' <<< "$PAGE") || return
        fi

        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0
    fi

    if match '^[[:space:]]*var free_enabled = false;' "$PAGE"; then
        log_error 'No free download slots available'
        echo 300 # wait some arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Request download (use dummy "-d" to force a POST request)
    JSON=$(curl -b "$COOKIE_FILE" --referer "$URL" \
        -H 'X-Requested-With: XMLHttpRequest' -d '' \
        "$BASE_URL/io/ticket/slot/$FILE_ID") || return

    if [ "$JSON" != '{succ:true}' ]; then
        ERR=$(parse_json_quiet 'err' <<< "$JSON")

        # from 'http://uploaded.net/js/download.js' - 'function(limit)'
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
    WAIT=$(parse '<span>Current waiting period' \
        'period: <span>\([[:digit:]]\+\)</span>' <<< "$PAGE") || return
    wait $((WAIT + 1)) || return

    # from 'http://uploaded.net/js/download.js' - 'Recaptcha.create'
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6Lcqz78SAAAAAPgsTYF3UlGf2QFQCNuPMenuyHF3'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    JSON=$(curl -b "$COOKIE_FILE" --referer "$URL" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        "$BASE_URL/io/ticket/captcha/$FILE_ID") || return

    ERR=$(parse_json_quiet 'err' <<< "$JSON")

    if [ -n "$ERR" ]; then
        if [ "$ERR" = 'captcha' ]; then
            log_error 'Wrong captcha'
            captcha_nack "$ID"
            return $ERR_CAPTCHA
        fi

        captcha_ack "$ID"

        if [ "$ERR" = 'limit-dl' ]; then
            log_error 'Free download limit reached'
            echo 600 # wait some arbitrary time
            return $ERR_LINK_TEMP_UNAVAILABLE

        # You have reached the max. number of possible free downloads for this hour
        elif match 'possible free downloads for this hour' "$ERR"; then
            log_error 'Hourly limit reached.'
            echo 3600
            return $ERR_LINK_TEMP_UNAVAILABLE

        # This file exceeds the max. filesize which can be downloaded by free users.
        elif match 'exceeds the max. filesize' "$ERR"; then
            return $ERR_SIZE_LIMIT_EXCEEDED

        # We're sorry but all of our available download slots are busy currently
        elif match 'all of our available download slots are busy' "$ERR"; then
            log_error 'No free download slots available'
            echo 300 # wait some arbitrary time
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    captcha_ack "$ID"

    # {type:'download',url:'http://storXXXX.uploaded.net/dl/...'}
    # Note: This is no valid JSON due to the unquoted/single quoted strings
    FILE_URL=$(uploaded_net_parse_json_alt 'url' <<< "$JSON") || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to Uploaded.net
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: ul.to download link
uploaded_net_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://uploaded.net'
    local -r MAX_SIZE=1073741823
    local PAGE SERVER FILE_ID AUTH_DATA ACCOUNT FOLDER_ID OPT_FOLDER

    # Sanity checks
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

    PAGE=$(curl "$BASE_URL/js/script.js") || return
    SERVER=$(parse 'uploadServer =' "[[:space:]]'\([^']*\)" <<< "$PAGE") || return

    log_debug "Upload server: $SERVER"

    ACCOUNT=$(uploaded_net_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return

    if [ "$ACCOUNT" != 'premium' ]; then
        local SIZE
        SIZE=$(get_filesize "$FILE") || return

        if [ $SIZE -gt $MAX_SIZE ]; then
            log_debug "File is bigger than $MAX_SIZE"
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    # If user chose a folder, check it now
    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(uploaded_net_check_folder "$FOLDER" "$COOKIE_FILE" \
            "$BASE_URL") || return
        OPT_FOLDER="&folder=$FOLDER_ID"
    fi
    log_debug "Folder ID: $FOLDER_ID"

    AUTH_DATA=$(parse_cookie 'login' < "$COOKIE_FILE" | uri_decode | \
        parse . '^\(&id=.\+&pw=.\+\)&cks=') || return

    PAGE=$(curl_with_log --user-agent 'Shockwave Flash' \
        -F "Filename=$DEST_FILE" \
        -F "Filedata=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        -F 'Upload=Submit Query' \
        "${SERVER}upload?admincode=$ADMIN_CODE$AUTH_DATA$OPT_FOLDER") || return

    if match '<title>504 Gateway Time-out</title>' "$PAGE"; then
        log_error 'Remote server error, maybe due to overload.'
        echo 120 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FILE_ID=${PAGE%%,*}

    # Sanity check
    if [ -z "$FILE_ID" ]; then
        log_error "Upstream error: '$PAGE'"
        return $ERR_FATAL
    elif [ "$FILE_ID" = 'forbidden' ]; then
        log_error 'Upstream error: file hash was blacklisted or try with another file.'
        return $ERR_FATAL
    fi

    # Do we need to edit the file? (change visibility, set password)
    if [ -n "$PRIVATE_FILE" -o -n "$LINK_PASSWORD" ]; then
        log_debug 'Editing file...'
        local OPT_PRIV='true'

        [ -n "$LINK_PASSWORD" ] && OPT_PRIV=$LINK_PASSWORD

        # Note: Site uses the same API call to set file private or set a password
        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "auth=$FILE_ID" -d "priv=$OPT_PRIV" \
            "$BASE_URL/api/file/priv") || return

        if [ "$PAGE" != '{"succ":"true"}' ]; then
            log_error 'Could not set password/private. Site updated?'
        fi
    fi

    echo "http://ul.to/$FILE_ID"
    echo
    echo "$ADMIN_CODE"
}

# Delete a file on Uploaded.net
# $1: cookie file
# $2: uploaded.net (download) link
uploaded_net_delete() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://uploaded.net'
    local URL PAGE FILE_ID

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    # Get canonical URL
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

    uploaded_net_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" >/dev/null || return

    FILE_ID=$(uploaded_net_extract_file_id "$URL" "$BASE_URL") || return
    PAGE=$(curl -b "$COOKIE_FILE" -H 'X-Requested-With: XMLHttpRequest' \
        -d "file%5B%5D=$FILE_ID" "$BASE_URL/api/Remove") || return

    # {"succ":1,"trust":0}
    [ "$PAGE" = '{"succ":1,"trust":0}' ] || return $ERR_FATAL
}

# List an Uploaded.net shared file folder URL
# $1: uploaded.net url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
uploaded_net_list() {
    local URL=$1
    local PAGE LINKS NAMES

    # check whether it looks like a folder link
    if ! match "${MODULE_UPLOADED_NET_REGEXP_URL}f\(older\)\?/" "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    PAGE=$(curl -L "$URL") || return

    LINKS=$(parse_all_attr 'tr id="' 'id' <<< "$PAGE") || return
    NAMES=$(parse_all_tag_quiet 'onclick="visit($(this))' 'a' <<< "$PAGE")

    test "$LINKS" || return $ERR_LINK_DEAD

    list_submit "$LINKS" "$NAMES" 'http://uploaded.net/file/' || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: Uploaded.net url
# $3: requested capability list
# stdout: 1 capability per line
uploaded_net_probe() {
    local -r REQ_IN=$3
    local -r BASE_URL='http://uploaded.net'
    local URL PAGE REQ_OUT FILE_ID FILE_SIZE

    # Uploaded.net redirects all possible urls of a file to the canonical one
    # Note: There can be multiple redirections before the final one
    URL=$(curl --head --location "$2" | grep_http_header_location_quiet | \
        last_line) || return
    [ -n "$URL" ] || URL=$2

    # Page not found
    # The requested file isn't available anymore!
    [[ $URL = */404 || $URL = */410/* ]]  && return $ERR_LINK_DEAD
    REQ_OUT=c

    FILE_ID=$(uploaded_net_extract_file_id "$URL" "$BASE_URL") || return
    PAGE=$(curl --location "$BASE_URL/file/$FILE_ID/status") || return

    if [[ $REQ_IN = *f* ]]; then
        first_line <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(last_line <<< "$PAGE" | replace_all '.' '' | replace_all ',' '.') \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
