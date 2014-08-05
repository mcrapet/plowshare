# Plowshare netkups.com module
# Copyright (c) 2014 Plowshare team
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

MODULE_NETKUPS_REGEXP_URL='http://\(www\.\)\?netkups\.com/'

MODULE_NETKUPS_DOWNLOAD_OPTIONS=""
MODULE_NETKUPS_DOWNLOAD_RESUME=no
MODULE_NETKUPS_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_NETKUPS_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_NETKUPS_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_NETKUPS_UPLOAD_REMOTE_SUPPORT=no

MODULE_NETKUPS_PROBE_OPTIONS=""

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
netkups_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local PAGE LOGIN_DATA USER_COOKIE

    LOGIN_DATA='username=$USER&password=$PASSWORD'

    post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL/?page=login" >/dev/null || return

    USER_COOKIE=$(parse_cookie_quiet 'user' < "$COOKIE_FILE")

    if [ -z "$USER_COOKIE" ]; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a netkups.com file download URL
# $1: cookie file
# $2: netkups.com url
# stdout: real file download link
netkups_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(replace '://www.' '://' <<< "$2")

    local PAGE FILE_URL FILE_NAME

    PAGE=$(curl "$URL") || return

    if match 'File not found\|This file has been deleted' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(parse 'File name:</strong> ' 'File name:</strong> \([^<]\+\)' <<< "$PAGE") || return

    local PUBKEY WCI CHALLENGE WORD ID

    # http://www.google.com/recaptcha/api/challenge?k=
    # http://api.recaptcha.net/challenge?k=
    PUBKEY=$(echo "$PAGE" | parse 'recaptcha.*?k=' '?k=\([[:alnum:]_-.]\+\)') || return
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    PAGE=$(curl \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        "$URL") || return

    FILE_URL=$(parse_attr_quiet 'big_dd_new' 'href' <<< "$PAGE") || return

    if [ -z "$FILE_URL" ]; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to netkups.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
netkups_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://netkups.com'

    local PAGE UPLOAD_ID UPLOAD_KEY UPLOAD_SERVER UPLOAD_PROCESS

    if [ -n "$AUTH" ]; then
        netkups_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        "$BASE_URL/ajax.php?action=upload") || return

    UPLOAD_ID=$(parse_json 'id' <<< "$PAGE") || return
    UPLOAD_KEY=$(parse_json 'key' <<< "$PAGE") || return
    UPLOAD_SERVER=$(parse_json 'server' <<< "$PAGE") || return
    UPLOAD_PROCESS=$(parse_json 'process' <<< "$PAGE") || return

    PAGE=$(curl_with_log \
        -F "name=$DEST_FILE" \
        -F "file=@$FILE;filename=$DEST_FILE" \
        "http://d$UPLOAD_SERVER.netkups.com/upload?id=$UPLOAD_ID&key=$UPLOAD_KEY") || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        "$BASE_URL/?finish=$UPLOAD_KEY&process=$UPLOAD_PROCESS") || return

    parse 'id="linkd" value="' 'id="linkd" value="\([^"]\+\)' <<< "$PAGE" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: netkups.com url
# $3: requested capability list
# stdout: 1 capability per line
netkups_probe() {
    local -r URL=$(replace '://www.' '://' <<< "$2")
    local -r REQ_IN=$3

    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl "$URL") || return

    if match 'File not found\|This file has been deleted' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    if [[ $REQ_IN = *f* ]]; then
        parse 'File name:</strong> ' \
        'File name:</strong> \([^<]\+\)' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'File size:</strong> ' \
        'File size:</strong> \([^<]\+\)' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
