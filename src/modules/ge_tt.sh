# Plowshare ge.tt module
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
#
# Official API: https://open.ge.tt/1/doc/rest

MODULE_GE_TT_REGEXP_URL='http://\(www\.\)\?ge\.tt/'

MODULE_GE_TT_DOWNLOAD_OPTIONS=""
MODULE_GE_TT_DOWNLOAD_RESUME=yes
MODULE_GE_TT_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_GE_TT_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_GE_TT_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
FOLDER,,folder,s=FOLDER,Folder to upload files into"
MODULE_GE_TT_UPLOAD_REMOTE_SUPPORT=no

MODULE_GE_TT_LIST_OPTIONS=""
MODULE_GE_TT_LIST_HAS_SUBFOLDERS=no

MODULE_GE_TT_PROBE_OPTIONS=""

# Full urldecode
# $1: url encoded string
# stdout: decoded string
ge_tt_urldecode(){
  echo -e "$(sed 's/+/ /g;s/%\(..\)/\\x\1/g;')"
}

# curl wrapper to handle all json requests
# $@: curl arguments
# stdout: JSON content
ge_tt_curl_json() {
    local PAGE ERROR

    PAGE=$(curl "$@") || return

    ERROR=$(parse_json_quiet 'error' <<< "$PAGE")

    if [ -n "$ERROR" ]; then
        if [ "$ERROR" = 'User not found' ]; then
            return $ERR_LOGIN_FAILED

        elif [ "$ERROR" = 'share not found' ] || \
            [ "$ERROR" = 'file not found' ]; then
            return $ERR_LINK_DEAD

        else
            log_error "Remote error: $ERROR"
            return $ERR_FATAL
        fi
    fi

    echo "$PAGE"
}

# Output a ge.tt file download URL
# $1: cookie file (unused here)
# $2: ge.tt url
# stdout: real file download link
ge_tt_download() {
    local -r URL=$2

    local PAGE LOCATION FILE_ID SHARE_ID

    FILE_ID=$(parse . '/\([^/]\+\)$' <<< "$URL") || return
    SHARE_ID=$(parse . '\.tt/\([^/]\+\)' <<< "$URL") || return

    PAGE=$(curl -i "https://open.ge.tt/1/files/$SHARE_ID/$FILE_ID/blob") || return

    if match '404 Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    LOCATION=$(grep_http_header_location <<< "$PAGE") || return

    echo "$LOCATION"
}

# Upload a file to ge.tt
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
ge_tt_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='https://open.ge.tt'

    local PAGE SESSION ACC_TOKEN FREE_SPACE
    local POST_URL SHARE_ID FILE_ID FILE_URL TRY FILE_STATE

    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        PAGE=$(curl -c "$COOKIE_FILE" 'http://ge.tt') || return

        SESSION=$(parse_cookie 'session' < "$COOKIE_FILE") || return
        SESSION=$(ge_tt_urldecode <<< "$SESSION") || return

    else
        local USER PASSWORD

        split_auth "$AUTH" USER PASSWORD || return

        SESSION=$(ge_tt_curl_json -X POST -H 'Content-type: application/json' \
            -d "{\"email\":\"$USER\",\"password\":\"$PASSWORD\"}" \
            'http://ge.tt/u/login') || return
    fi

    ACC_TOKEN=$(parse_json 'accesstoken' <<< "$SESSION") || return
    FREE_SPACE=$(parse_json 'free' <<< "$SESSION") || return

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$FREE_SPACE" ]; then
        log_debug "File is bigger than $FREE_SPACE."
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$FOLDER" ]; then
        PAGE=$(ge_tt_curl_json "$BASE_URL/1/shares?accesstoken=$ACC_TOKEN") || return

        if ! match "\"title\":\"$FOLDER\"" "$PAGE"; then
            log_debug "Creating share with title '$FOLDER'..."

            PAGE=$(ge_tt_curl_json -X POST -H 'Content-type: application/json' \
                -d "{\"title\":\"$FOLDER\"}" \
                "$BASE_URL/1/shares/create?accesstoken=$ACC_TOKEN") || return

            SHARE_ID=$(parse_json 'sharename' <<< "$PAGE") || return
        else
            PAGE=$(replace_all '}' $'}\n' <<< "$PAGE")

            SHARE_ID=$(parse "\"title\":\"$FOLDER\"" '"sharename":"\([^"]\+\)' <<< "$PAGE") || return
        fi
    else
        PAGE=$(ge_tt_curl_json -X POST "$BASE_URL/1/shares/create?accesstoken=$ACC_TOKEN") || return

        SHARE_ID=$(parse_json 'sharename' <<< "$PAGE") || return
    fi

    PAGE=$(ge_tt_curl_json -X POST -H 'Content-type: application/json' \
        -d "{\"filename\":\"$DEST_FILE\"}" \
        "$BASE_URL/1/files/$SHARE_ID/create?accesstoken=$ACC_TOKEN") || return

    FILE_ID=$(parse_json 'fileid' <<< "$PAGE") || return
    POST_URL=$(parse_json 'posturl' <<< "$PAGE") || return

    PAGE=$(curl_with_log \
        -F "Filedata=@$FILE;filename=$DEST_FILE" \
        "$POST_URL") || return

    # Upload state check can be skipped actually, but it is more correct
    # if match 'computer says yes' "$PAGE"; then
    #     PAGE=$(curl "https://open.ge.tt/1/files/$SHARE_ID/$FILE_ID") || return
    #     FILE_URL=$(parse_json 'getturl' <<< "$PAGE") || return
    #     echo "$FILE_URL"
    #     return 0
    # fi

    TRY=1
    while [ "$FILE_STATE" != 'uploaded' ]; do
        PAGE=$(ge_tt_curl_json "$BASE_URL/1/files/$SHARE_ID/$FILE_ID") || return

        FILE_STATE=$(parse_json 'readystate' <<< "$PAGE") || return

        [ "$FILE_STATE" = 'uploaded' ] && break

        if [ "$FILE_STATE" != 'uploading' ]; then
            log_error "Upload failed. Unknown state: '$FILE_STATE'."
            return $ERR_FATAL
        fi

        log_debug "Wait for server to recieve the file... [$((TRY++))]"
        wait 1 || return
    done

    FILE_URL=$(parse_json 'getturl' <<< "$PAGE") || return

    echo "$FILE_URL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: ge.tt url
# $3: requested capability list
# stdout: 1 capability per line
ge_tt_probe() {
    local -r URL=$2
    local -r REQ_IN=$3

    local PAGE FILE_ID SHARE_ID FILE_SIZE

    FILE_ID=$(parse . '/\([^/]\+\)$' <<< "$URL") || return
    SHARE_ID=$(parse . '\.tt/\([^/]\+\)' <<< "$URL") || return

    PAGE=$(ge_tt_curl_json "https://open.ge.tt/1/files/$SHARE_ID/$FILE_ID") || return

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_json 'filename' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_json 'size' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a ge.tt web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
ge_tt_list() {
    local -r URL=$1
    local -r REC=$2

    local PAGE SHARE_ID NAMES LINKS

    SHARE_ID=$(parse . '\.tt/\([^/]\+\)' <<< "$URL") || return

    PAGE=$(ge_tt_curl_json "https://open.ge.tt/1/shares/$SHARE_ID") || return

    LINKS=$(parse_json_quiet 'getturl' 'split' <<< "$PAGE")
    LINKS=$(delete_first_line <<< "$LINKS")

    NAMES=$(parse_json_quiet 'filename' 'split' <<< "$PAGE")

    list_submit "$LINKS" "$NAMES"
}
