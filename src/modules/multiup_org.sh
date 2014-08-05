# Plowshare multiup.org module
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

MODULE_MULTIUP_ORG_REGEXP_URL='https\?://\(www\.\)\?multiup\.org/'

MODULE_MULTIUP_ORG_LIST_OPTIONS=""
MODULE_MULTIUP_ORG_LIST_HAS_SUBFOLDERS=no

MODULE_MULTIUP_ORG_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account (mandatory)
FAVORITES,,favorites,,Only upload to user's favorite hosts"
MODULE_MULTIUP_ORG_UPLOAD_REMOTE_SUPPORT=no

MODULE_MULTIUP_ORG_PROBE_OPTIONS=""

# Static function. Proceed with login (free or premium)
multiup_org_login() {
    local -r BASE_URL=$3
    local JSON ERR

    JSON=$(curl -F "username=$1" -F "password=$2" \
        "$BASE_URL/login") || return

    # {"error":"success","login":"bob","user":123456}
    # {"error":"bad username OR bad password"}
    ERR=$(parse_json 'error' <<< "$JSON")

    if [ "$ERR" = 'success' ]; then
        parse_json 'user' <<< "$JSON" || return
        return 0
    elif match 'bad ' "$ERR"; then
         return $ERR_LOGIN_FAILED
    else
        log_error "Remote error: $ERR"
        return $ERR_FATAL
    fi
}

# Upload a file to multiup.org
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: multiup.org download link
multiup_org_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r API_URL='http://www.multiup.org/api'
    local USER PASSWORD USER_ID JSON ERR SERVER H FORM_FIELDS
    local -a H1 H2

    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS
    split_auth "$AUTH_FREE" USER PASSWORD || return

    USER_ID=$(multiup_org_login "$USER" "$PASSWORD" "$API_URL") || return
    log_debug "uid: '$USER_ID'"

    # Get fastest server
    JSON=$(curl "$API_URL/get-fastest-server") || return

    ERR=$(parse_json 'error' <<< "$JSON")
    if [ "$ERR" != 'success' ]; then
        log_error "Remote error: $ERR"
        return $ERR_FATAL
    fi

    SERVER=$(parse_json 'server' <<< "$JSON") || return
    log_debug "server: '$SERVER'"

    # Get list available hosts
    # {"error":"success","hosts":{"1fichier.com":2048,"billionuploads.com":2048, ...},"disableHosts":["billionuploads.com","dfiles.eu"]}
    JSON=$(curl -F "username=$USER" -F "password=$PASSWORD" \
        "$API_URL/get-list-hosts") || return

    ALL_HOSTS=$(parse_json hosts <<< "$JSON") || return
    DIS_HOSTS=$(parse_json disableHosts <<< "$JSON") || return

    # Att: Hoster names must not contain IFS chatacters..
    IFS=',{}' read -r -a H1 <<< "$ALL_HOSTS"
    IFS=',[]' read -r -a H2 <<< "$DIS_HOSTS"

    H1=(${H1[@]/#\"})
    H2=(${H2[@]/#\"})
    H1=(${H1[@]/\"*})
    H2=(${H2[@]/%\"})

    log_debug "available hosters: ${H1[@]}"

    if [ -n "$FAVORITES" ]; then
        # Process H1 - H2
        # Att: Hoster names must not be substring of each other
        for H in "${H2[@]}"; do
            H1=(${H1[@]/$H})
        done
        log_debug "favorites hosters: ${H1[@]}"
    fi

    for H in "${H1[@]}"; do
        FORM_FIELDS="$FORM_FIELDS -F $H=true"
    done

    JSON=$(curl_with_log -F "user=$USER_ID" \
        -F "files[]=@$FILE;filename=$DESTFILE" \
        $FORM_FIELDS "$SERVER") || return

    parse_json 'url' <<< "$JSON" || return
    parse_json 'delete_url' <<< "$JSON"
    return 0
}

# List links from a multiup.org link
# $1: multiup.org url
# $2: recurse subfolders (ignored here)
# stdout: list of links
multiup_org_list() {
    local -r URL=$(replace '/miror/' '/download/' <<<"$1")
    local -r BASE_URL='http://www.multiup.org'
    local COOKIE_FILE PAGE LINK LINKS NAMES

    # Set-Cookie: PHPSESSID=...; yooclick=true; ...
    COOKIE_FILE=$(create_tempfile) || return
    PAGE=$(curl -L -c "$COOKIE_FILE" "$URL") || return

    LINK=$(parse_quiet 'class=.btn.' 'href=.\([^"]*\)' 1 <<< "$PAGE")
    if [ -n "$LINK" ]; then
        LINK=$(replace '/fr/' '/en/' <<< "$LINK")
        PAGE=$(curl -b "$COOKIE_FILE" --referer "$URL" "$BASE_URL$LINK") || return
    fi

    rm -f "$COOKIE_FILE"

    LINKS=$(parse_all_quiet 'dateLastChecked=' 'href=.\([^"]*\)' 3 <<< "$PAGE")
    if [ -z "$LINKS" ]; then
        # <h3>File currently uploading ...</h3>
        if match '>File currently uploading \.\.\.<' "$PAGE"; then
            local N=$(parse '>File position in queue' '[[:space:]]:[[:space:]]\([[:digit:]]\+\)<' <<< "$PAGE")
            log_debug "file position in queue: '$N'"
            return $ERR_LINK_TEMP_UNAVAILABLE
        else
            log_error 'No links found. Site updated?'
            return $ERR_FATAL
        fi
    fi

    NAMES=$(parse_all_quiet 'dateLastChecked=' 'nameHost=.\([^"]*\)' -2 <<< "$PAGE")

    list_submit "$LINKS" "$NAMES" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: multiup.org url
# $3: requested capability list
# stdout: 1 capability per line
multiup_org_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local JSON REQ_OUT FILE_NAME HASH

    # Notes relatinf to offcial API:
    # - don't provide file size
    # - provides both md5 & sha1
    JSON=$(curl -F "link=$URL" 'http://www.multiup.org/api/check-file') || return

    # {"error":"link is empty"}
    # {"error":"success", ...}
    ERR=$(parse_json error <<< "$JSON") || return
    if [ "$ERR" != 'success' ]; then
        log_debug "Remote error: $ERR"
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse_json 'file_name' <<< "$JSON") && \
            echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *h* ]]; then
        HASH=$(parse_json 'md5_checksum' <<< "$JSON") && \
            echo "$HASH" && REQ_OUT="${REQ_OUT}h"
    fi

    echo $REQ_OUT
}
