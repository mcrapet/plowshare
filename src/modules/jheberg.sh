# Plowshare jheberg.net module
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

MODULE_JHEBERG_REGEXP_URL='http://\(www\.\)\?jheberg\.net/'

MODULE_JHEBERG_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_JHEBERG_UPLOAD_REMOTE_SUPPORT=no

MODULE_JHEBERG_LIST_OPTIONS=""
MODULE_JHEBERG_LIST_HAS_SUBFOLDERS=no

# Upload a file to Jheberg.net
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: jheberg.net download link
jheberg_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r API_URL='http://www.jheberg.net/api/'
    local PAGE UPLOAD_URL JSON USER PASSWORD

    # Note: official API does not allow hoster selection (yet).

    PAGE=$(curl "$API_URL/get/server/") || return
    UPLOAD_URL="$(echo "$PAGE" | parse_json 'url')api/upload/" || return
    log_debug "Upload URL: $UPLOAD_URL"

    if [ -n "$AUTH" ]; then
        split_auth "$AUTH" USER PASSWORD || return
        JSON=$(curl_with_log -F "file=@$FILE;filename=$DESTFILE" \
            -F "username=$USER" -F "password=$PASSWORD" \
            "$UPLOAD_URL") || return
    else
        JSON=$(curl_with_log -F "file=@$FILE;filename=$DESTFILE" \
            "$UPLOAD_URL") || return
    fi

    if match_json_true 'error' "$JSON"; then
        local ERR=$(echo "$JSON" | parse_json 'error_string')
        if matchi 'bad credentials' "$ERR"; then
            return $ERR_LOGIN_FAILED
        else
            log_error "Remote error: $ERR"
            return $ERR_FATAL
        fi
    fi

    echo "$JSON" | parse_json 'url' || return
}

# List links from a Jheberg link
# $1: jheberg link
# $2: recurse subfolders (ignored here)
# stdout: list of links
jheberg_list() {
    local -r URL=${1/\/captcha\///download/}
    local -r BASE_URL='http://jheberg.net'
    local JSON NAMES DL_ID URL2 HOSTER

    JSON=$(curl --get --data "id=$(uri_encode_strict <<< "$URL")" \
        "$BASE_URL/api/verify/file/") || return

    if [ -z "$JSON" ] || match '^<!DOCTYPE[[:space:]]' "$JSON"; then
        return $ERR_LINK_DEAD
    fi

    # FIXME. Fragile parsing...
    JSON=$(sed -e 's/},/\n/g' <<< "$JSON" | \
        sed -ne '/"hostOnline":[[:space:]]*true/p')

    NAMES=$(parse_json 'hostName' split <<< "$JSON")

    # All mirrors have been deleted!
    if [ -z "$NAMES" ]; then
        return $ERR_LINK_DEAD
    fi

    DL_ID=$(parse . '^.*/\([^/]\+\)' <<< "$URL") || return
    log_debug "slug: '$DL_ID'"

    while read HOSTER; do
        URL2="${URL/\/mirrors\///redirect/}$HOSTER/"

        JSON=$(curl --referer "$URL2" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d "slug=$DL_ID" -d "hoster=$HOSTER"    \
            "$BASE_URL/get/link/") || return

        URL2=$(echo "$JSON" | parse_json_quiet url)
        if match_remote_url "$URL2"; then
            echo "$URL2"
            echo "$HOSTER"
        fi
    done <<< "$NAMES"
}

# Probe a download URL (using official API)
# $1: cookie file (unused here)
# $2: jheberg url
# $3: requested capability list
# stdout: 1 capability per line
jheberg_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local JSON REQ_OUT FILE_SIZE

    JSON=$(curl --get --data "id=$(uri_encode_strict <<< "$URL")" \
        "http://jheberg.net/api/verify/file/") || return

    if [ -z "$JSON" ] || match '^<!DOCTYPE[[:space:]]' "$JSON"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_json 'fileName' split <<< "$JSON" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        parse_json 'fileSize' split <<< "$JSON" && \
            REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
