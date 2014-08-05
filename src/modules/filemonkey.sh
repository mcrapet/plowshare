# Plowshare filemonkey.in module
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

MODULE_FILEMONKEY_REGEXP_URL='https\?://\(www\.\)\?filemonkey\.in/'

MODULE_FILEMONKEY_UPLOAD_OPTIONS="
FOLDER,,folder,s=FOLDER,Folder to upload files into (root folder child ONLY!)
CREATE_FOLDER,,create,,Create folder if it does not exist
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account"
MODULE_FILEMONKEY_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base url
filemonkey_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE STATUS ERR

    LOGIN_DATA='email=$USER&password=$PASSWORD'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login") || return

    STATUS=$(parse_cookie_quiet 'logincookie' < "$COOKIE_FILE")
    if [ -z "$STATUS" ]; then
        ERR=$(parse_tag_quiet 'alert-danger' div <<< "$PAGE")
        log_debug "Remote error: '$ERR'"
        return $ERR_LOGIN_FAILED
    fi
}

# Upload a file to Filemonkey.in
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
filemonkey_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='https://www.filemonkey.in'
    local PAGE API_KEY FID UPLOAD_URL JSON STATUS

    # Sanity check
    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS

    if [ -n "$CREATE_FOLDER" -a -z "$FOLDER" ]; then
        log_error '--folder option required'
        return $ERR_BAD_COMMAND_LINE
    fi

    filemonkey_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/manage") || return

    # Get upload url, apikey and folder
    API_KEY=$(parse "'apikey'" ":[[:space:]]*'\([^']\+\)" <<< "$PAGE") || return
    log_debug "apikey: '$API_KEY'"

    if [ -z "$FOLDER" ]; then
        FID=$(parse "'folder'" ":[[:space:]]*'\([^']\+\)" <<< "$PAGE") || return
        log_debug "root folder: '$FID'"
    else
        FID=$(parse_attr_quiet ">$FOLDER<" data-pk <<< "$PAGE")

        # Create a folder (root folder is parent)
        # POST /manage?folder=xxx
        if [ -z "$FID" ]; then
            if [ -n "$CREATE_FOLDER" ]; then
                PAGE=$(curl -b "$COOKIE_FILE" --referer "$BASE_URL/manage" \
                    -d "newfolder_name=$FOLDER" \
                    -d 'action=createfolder' \
                    "$BASE_URL/manage") || return

                if [ -z "$PAGE" ]; then
                    log_error 'An error has occured. Remote folder alread exists?'
                    return $ERR_FATAL
                fi

                FID=$(parse_attr ">$FOLDER<" data-pk <<< "$PAGE") || return
            else
                log_error 'Folder does not seem to exist. Use --create switch.'
                return $ERR_FATAL
            fi
        fi
        log_debug "child folder: '$FID'"
    fi

    UPLOAD_URL=$(parse '://dl-' "=[[:space:]]*'\([^']\+\)" <<< "$PAGE") || return
    log_debug "upload url: '$UPLOAD_URL'"

    # No cookie required here
    # Answers:
    # {"status":"success","response":{"filename":"foo.zip","extid":"ki1tqa3u369b46s7","md5":"13f5efdc3b88c4076f80b9615bf12312"}}
    # {"status":"error","error":"duplicate_file_in_folder"}
    JSON=$(curl_with_log --referer "$BASE_URL/manage" -H "Origin: $BASE_URL" \
        -F "apikey=$API_KEY" \
        -F "folder=$FID" \
        -F "file=@$FILE;filename=$DESTFILE" "$UPLOAD_URL") || return

    STATUS=$(parse_json 'status' <<< "$JSON") || return

    if [ "$STATUS" != 'success' ]; then
        local ERR=$(parse_json 'error' <<< "$JSON")
        log_error "Remote error: '$ERR'"
        return $ERR_FATAL
    fi

    STATUS=$(parse_json 'extid' <<< "$JSON") || return

    echo "$BASE_URL/file/$STATUS"
}
