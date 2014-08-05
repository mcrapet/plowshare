# Plowshare uploadhero.co module
# Copyright (c) 2012-2014 Plowshare team
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

MODULE_UPLOADHERO_REGEXP_URL='http://\(www\.\)\?\(uploadhero\)\.com\?/'

MODULE_UPLOADHERO_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_UPLOADHERO_DOWNLOAD_RESUME=no
MODULE_UPLOADHERO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_UPLOADHERO_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_UPLOADHERO_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_UPLOADHERO_UPLOAD_REMOTE_SUPPORT=no

MODULE_UPLOADHERO_LIST_OPTIONS=""
MODULE_UPLOADHERO_LIST_HAS_SUBFOLDERS=yes

MODULE_UPLOADHERO_DELETE_OPTIONS=""
MODULE_UPLOADHERO_PROBE_OPTIONS=""

# Set a cookie manually
#
# Note: This function assumes no cookie of the given name is present. It cannot
#       change values of existing cookies!
#
# $1: cookie file
# $2: name
# $3: value
# $4: domain
# $5: path (defaults to "/")
# $6: expiration date (unix timestamp, defaults to "0", i.e. session cookie)
# $7: secure only (set to any value to create secured cookie)
uploadhero_cookie_set() {
    local -r PATH=${5:-/}
    local -r EXP=${6:-0}
    local SEC FLAG

    if [ '.' = "${4:0:1}" ]; then
        FLAG='TRUE'
    else
        FLAG='FALSE'
    fi

    if [ -n "$7" ]; then
        SEC='TRUE'
    else
        SEC='FALSE'
    fi

    # Cookie file syntax:
    # http://www.hashbangcode.com/blog/netscape-http-cooke-file-parser-php-584.html
    echo "$4	$FLAG	$PATH	$SEC	$EXP	$2	$3" >> "$1"
}

# Switch language to english
# $1: cookie file
# $2: base URL
uploadhero_switch_lang() {
    uploadhero_cookie_set "$1" 'lang' 'en' "${2#http://}" || return
}

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
uploadhero_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA STATUS USER

    LOGIN_DATA='pseudo_login=$USER&password_login=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/lib/connexion.php") || return

    # Username or password invalid.
    if match 'Username or password invalid' "$LOGIN_RESULT"; then
        return $ERR_LOGIN_FAILED
    fi

    split_auth "$AUTH" USER || return
    log_debug "Successfully logged in as member '$USER'"
}

# Output an UploadHero file download URL
# $1: cookie file
# $2: uploadhero url
# stdout: real file download link
uploadhero_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(echo "$2" | replace 'www.' '' | replace '/v/' '/dl/')
    local FILE_ID PAGE FILE_NAME FILE_URL CAPTCHA_URL CAPTCHA_IMG

    # Can be .com or .co
    local -r BASE_URL=$(basename_url "$URL")

    # Recognize folders
    if match 'uploadhero.com\?/f/' "$URL"; then
        log_error 'This is a directory list'
        return $ERR_FATAL
    fi

    uploadhero_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    if [ -n "$AUTH_FREE" ]; then
        uploadhero_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -L -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    # You are currently using a dedicated server, this is not allowed by our T.O.S.
    if match '<title>UploadHero - VPN</title>' "$PAGE"; then
        log_error 'You are currently using a dedicated server, this is not allowed.'
        return $ERR_FATAL
    fi

    # Verify if link exists
    match '<div class="raison">' "$PAGE" && return $ERR_LINK_DEAD

    # Check limit (one file every 20 minutes)
    if match 'id="lightbox_block_dl"' "$PAGE"; then
        local LIMIT_URL LIMIT_HTML LIMIT_MIN LIMIT_SEC WAIT_TIME

        LIMIT_URL=$(echo "$PAGE" | parse_attr 'id="lightbox_block_dl"' href)
        LIMIT_HTML=$(curl "$BASE_URL$LIMIT_URL") || return
        LIMIT_MIN=$(echo "$LIMIT_HTML" | parse_tag 'id="minutes"' span)
        LIMIT_SEC=$(echo "$LIMIT_HTML" | parse_tag 'id="seconds"' span)
        WAIT_TIME=$(($LIMIT_MIN * 60 + $LIMIT_SEC + 1))

        log_error 'Forced delay between downloads.'
        echo $WAIT_TIME
        return $ERR_LINK_TEMP_UNAVAILABLE

    # 1GB file limit. Premium users only.
    elif match 'id="lightbox_1gbfile"' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    # Extract the raw file id
    FILE_ID=$(echo "$URL" | parse . '/dl/\([^/]*\)')
    log_debug "File id: '$FILE_ID'"

    # Extract filename (first <div> marker)
    FILE_NAME=$(parse_tag 'class="nom_de_fichier"' div <<< "$PAGE")

    # Handle captcha
    CAPTCHA_URL=$(echo "$PAGE" | parse_attr 'id="captcha"' 'src')
    log_debug "Captcha url: '$CAPTCHA_URL'"
    CAPTCHA_URL="$BASE_URL$CAPTCHA_URL"

    # Create new formatted image (cookie is mandatory)
    CAPTCHA_IMG=$(create_tempfile) || return
    curl --referer "$URL" -b "$COOKIE_FILE" -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || return

    # Decode captcha
    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG") || return
    { read WORD; read ID; } <<< "$WI"
    rm -f "$CAPTCHA_IMG"

    log_debug "decoded captcha: $WORD"

    # Get final URL
    PAGE=$(curl -b "$COOKIE_FILE" "$URL?code=$WORD") || return

    # name="code" id="captcha-form" style="border: solid 1px #c60000;"
    if match 'id="captcha-form" style="border:' "$PAGE"; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    elif match '(magicomfg)' "$PAGE"; then
        FILE_URL=$(parse_attr magicomfg href <<< "$PAGE") || return
    else
        log_error 'No match. Site update?'
        return $ERR_FATAL
    fi

    captcha_ack $ID
    log_debug 'correct captcha'

    # Note: we should parse the javascript function...
    wait 60 seconds || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to UploadHero
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: uploadhero download link
uploadhero_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://uploadhero.co'
    local -r MAX_SIZE=2147483648 # 2GiB
    local PAGE UP_URL SESSION_ID SIZE FILE_ID USER_ID

    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    uploadhero_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    if [ -n "$AUTH_FREE" ]; then
        uploadhero_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$BASE_URL") || return

    # upload_url: "http://c28.uploadhero.com/upload/upload.php",
    UP_URL=$(echo "$PAGE" | \
        parse 'upload_url' 'upload_url: "\(http://[^"]\+\)",') || return

    # post_params: {"PHPSESSID" : "ud2i8866uoeu6p2fehpvj218m2", "ID" : ""},
    SESSION_ID=$(echo "$PAGE" | \
        parse 'PHPSESSID' '{"PHPSESSID" : "\([[:alnum:]]\+\)",') || return

    if [ -n "$AUTH_FREE" ]; then
        USER_ID=$(echo "$PAGE" | parse '"ID"' \
            '"ID"[[:space:]]*:[[:space:]]*"\([^"]\+\)') || return
        FILE_ID=$(curl_with_log --user-agent 'Shockwave Flash' \
            -F "Filename=$DEST_FILE" \
            -F "ID=$USER_ID" \
            -F "PHPSESSID=$SESSION_ID" \
            -F "Filedata=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
            -F 'Upload=Submit Query' \
            "$UP_URL") || return
    else
        FILE_ID=$(curl_with_log --user-agent 'Shockwave Flash' \
            -F "Filename=$DEST_FILE" \
            -F "PHPSESSID=$SESSION_ID" \
            -F "Filedata=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
            -F 'Upload=Submit Query' \
            "$UP_URL") || return
    fi

    if [ -z "FILE_ID" ]; then
        log_error 'Could not upload file.'
        return $ERR_FATAL
    fi

    PAGE=$(curl --get -b "$COOKIE_FILE" --referer "$BASE_URL/home" \
        -d 'folder=' -d "name=$DEST_FILE" -d "size=$SIZE" \
        "$BASE_URL/fileinfo.php") || return

    # Output file link + delete link
    echo "$BASE_URL/dl/$FILE_ID"

    if [ -z "$AUTH_FREE" ]; then
        echo "$PAGE" | parse '/delete/' ">\($BASE_URL/delete/[[:alnum:]]\+\)<"
    fi
}

# Delete a file from UploadHero
# $1: cookie file (unused here)
# $2: uploadhero (delete) link
uploadhero_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://uploadhero.co'
    local PAGE REDIR DEL_ID

    PAGE=$(curl --include "$URL") || return

    # Note: Redirects to main page if file is already deleted
    REDIR=$(echo "$PAGE" | grep_http_header_location_quiet)
    [ "$REDIR" = '/' ] && return $ERR_LINK_DEAD

    DEL_ID=${URL##*/}
    PAGE=$(curl "$BASE_URL/apifull.php?deleteidok=$DEL_ID") || return

    if [ "$PAGE" != 'ok' ]; then
        log_error 'Could not delete file.'
        return $ERR_FATAL
    fi
}

# List an uploadhero shared file folder URL
# $1: uploadhero url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
uploadhero_list() {
    local URL=$1
    local PAGE NAMES LINKS

    # check whether it looks like a folder link
    if ! match "${MODULE_UPLOADHERO_REGEXP_URL}f/" "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    test "$2" && log_error "Recursive flag not implemented, ignoring"

    PAGE=$(curl -L "$URL") || return

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet '<td class="td4">' href)
    NAMES=$(echo "$PAGE" | parse_all_tag_quiet '<td class="td2">' td | html_to_utf8)

    list_submit "$LINKS" "$NAMES" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: uploadhero url
# $3: requested capability list
# stdout: 1 capability per line
uploadhero_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L -b 'lang=en' "$URL") || return

    # Verify if link exists
    match '<div class="raison">' "$PAGE" && return $ERR_LINK_DEAD

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'class="nom_de_fichier"' div <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse_tag 'Filesize:' strong ) && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
