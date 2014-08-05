# Plowshare bayimg.com module
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

MODULE_BAYIMG_REGEXP_URL='https\?://\(www\.\)\?bayimg\.com/'

MODULE_BAYIMG_DOWNLOAD_OPTIONS=""
MODULE_BAYIMG_DOWNLOAD_RESUME=yes
MODULE_BAYIMG_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_BAYIMG_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_BAYIMG_UPLOAD_OPTIONS="
ADMIN_CODE,,admin-code,s=ADMIN_CODE,Admin code (used for file deletion)
TAGS,,tags,l=LIST,Provide list of tags (comma separated)"
MODULE_BAYIMG_UPLOAD_REMOTE_SUPPORT=no

MODULE_BAYIMG_DELETE_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Admin password (mandatory)"
MODULE_BAYIMG_PROBE_OPTIONS=""

# Output a bayimg.com file download URL
# $1: cookie file (unused here)
# $2: bayimg url
# stdout: real file download link
bayimg_download() {
    local -r URL=$2
    local PAGE FILE_URL FILE_NAME

    PAGE=$(curl -L "$URL") || return

    if match '<title>404 . Not Found</title>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_URL=$(parse_attr 'toggleResize(' src <<< "$PAGE") || return

    # Filename is not always displayed
    FILE_NAME=$(parse_quiet '>Filename:' '<p>Filename:[[:space:]]\([^<]\+\)' <<< "$PAGE")

    echo "http:$FILE_URL"
    test -z "$FILE_NAME" || echo "$FILE_NAME"
}

# Upload a file to bayimg.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + admin code
bayimg_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local PAGE FILE_URL

    if [ -n "$ADMIN_CODE" ]; then
        # No known restrictions (length limitation or forbidden characters)
        :
    else
        ADMIN_CODE=$(random a 8)
    fi

    PAGE=$(curl_with_log -F "tags=${TAGS[*]}" \
        -F "code=$ADMIN_CODE" \
        -F "file=@$FILE;filename=$DESTFILE" \
        'http://bayimg.com/upload') || return

    FILE_URL=$(parse_attr 'image-setting' href <<< "$PAGE") || return

    echo "http:$FILE_URL"
    echo
    echo "$ADMIN_CODE"
}

# Delete a file on bayimg (requires an admin code)
# $1: cookie file (unused here)
# $2: delete link
bayimg_delete() {
    local -r URL=$2
    local PAGE REDIR

    if [ -z "$LINK_PASSWORD" ]; then
        LINK_PASSWORD=$(prompt_for_password) || return
    fi

    PAGE=$(curl -i "$URL" -d "code=$LINK_PASSWORD") || return

    if match '<strong>REMOVAL CODE</strong>' "$PAGE"; then
        return $ERR_LINK_PASSWORD_REQUIRED
    fi

    REDIR=$(grep_http_header_location_quiet <<< "$PAGE")
    if [ "$REDIR" = '/' ]; then
        return 0
    fi

    return $ERR_LINK_DEAD
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: bayfile url
# $3: requested capability list
# stdout: 1 capability per line
bayimg_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT

    PAGE=$(curl -L "$URL") || return

    if match '<title>404 . Not Found</title>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '>Filename:' '<p>Filename:[[:space:]]\([^<]\+\)' <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}f"
    fi

    echo $REQ_OUT
}
