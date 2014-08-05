# Plowshare gamefront.com module
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

MODULE_GAMEFRONT_REGEXP_URL='http://\(www\.\)\?gamefront\.com/files/[[:digit:]]\+'

MODULE_GAMEFRONT_DOWNLOAD_OPTIONS=""
MODULE_GAMEFRONT_DOWNLOAD_RESUME=yes
MODULE_GAMEFRONT_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_GAMEFRONT_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_GAMEFRONT_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_GAMEFRONT_UPLOAD_REMOTE_SUPPORT=no

MODULE_GAMEFRONT_PROBE_OPTIONS=""

# Static function. Proceed with login.
gamefront_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT LOCATION SUB_X SUB_Y

    SUB_X=$(random d 2)
    SUB_Y=$(random d 1)

    LOGIN_DATA="email=\$USER&password=\$PASSWORD&submit.x=$SUB_X&submit.y=$SUB_Y"
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        -i \
        "$BASE_URL/files/users/login") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$LOGIN_RESULT")

    if [ "$LOCATION" != 'http://www.gamefront.com/files/users/dashboard' ]; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a gamefront.com file download URL and name
# $1: cookie file
# $2: gamefront.com url
# stdout: file download link
gamefront_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2

    local PAGE LINK FILE_URL

    PAGE=$(curl -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    # The file you are looking for seems to be missing.
    if match 'File not found\|seems to be missing' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    LINK=$(parse_attr 'downloadLink' 'href' <<< "$PAGE") || return

    PAGE=$(curl -b "$COOKIE_FILE" "$LINK") || return

    if match 'File not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_URL=$(parse 'downloadUrl' "downloadUrl = '\([^']\+\)" <<< "$PAGE") || return

    echo "$FILE_URL"
}

# Upload a file to gamefront.com
# $1: cookie file
# $2: file path or remote url
# $3: remote filename
# stdout: download link
gamefront_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.gamefront.com'
    local -r MAX_SIZE=734003200 # 700 MiB

    local PAGE ERROR_CODE LINK_DL
    local FORM_HTML FORM_ACTION FORM_CALLBACK FORM_KEY FORM_HOST FORM_USERID FORM_TTL

    # Check for forbidden file extensions
    case ${DEST_FILE##*.} in
        rar|zip|7z|gz|exe|mov|mp4|avi|flv|wmv)
            ;;
        *)
            log_error 'File extension is forbidden. Allowed extensions: *.rar;*.zip;*.7z;*.gz;*.exe;*.mov;*.mp4;*.avi;*.flv;*.wmv.'
            return $ERR_FATAL
            ;;
    esac

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "File is bigger than $MAX_SIZE."
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$AUTH" ]; then
        gamefront_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$BASE_URL/files/upload") || return

    FORM_HTML=$(grep_form_by_id "$PAGE" 'bku-form') || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_CALLBACK=$(parse_form_input_by_name 'callback' <<< "$FORM_HTML") || return
    FORM_KEY=$(parse_form_input_by_name 'key' <<< "$FORM_HTML") || return
    FORM_HOST=$(parse_form_input_by_name 'host' <<< "$FORM_HTML") || return

    if [ -n "$AUTH" ]; then
        FORM_USERID=$(parse 'post_params' '"userId":"\([^"]\+\)' <<< "$PAGE") || return
        FORM_USERID="-F userId=$FORM_USERID"

        FORM_TTL=$(parse 'post_params' '"ttl":"\([^"]\+\)' <<< "$PAGE") || return
        FORM_TTL="-F ttl=$FORM_TTL"
    fi

    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -F "Filename=$DESTFILE" \
        -F "callback=$FORM_CALLBACK" \
        -F "key=$FORM_KEY" \
        $FORM_USERID \
        -F "host=$FORM_HOST" \
        $FORM_TTL \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        -F "Upload=Submit Query" \
        "$FORM_ACTION") || return

    ERROR_CODE=$(parse_json 'errorCode' <<< "$PAGE") || return

    if [ "$ERROR_CODE" != 0 ]; then
        log_error "Upload failed. Error code: $ERROR_CODE."
        return $ERR_FATAL
    fi

    LINK_DL=$(parse_json 'url' <<< "$PAGE") || return

    echo "$LINK_DL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: gamefront.com url
# $3: requested capability list
# stdout: 1 capability per line
gamefront_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -L "$URL") || return

    # The file you are looking for seems to be missing.
    if match 'File not found\|seems to be missing' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '<dt>File Name:</dt>' '<dd>\([^<]\+\)' 1 <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '<dt>File Size:</dt>' '<dd>\([^<]\+\)' 1 <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
