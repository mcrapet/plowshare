# Plowshare promptfile.com module
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

MODULE_PROMPTFILE_REGEXP_URL='http://\(www\.\)\?promptfile\.com/'

MODULE_PROMPTFILE_DOWNLOAD_OPTIONS=""
MODULE_PROMPTFILE_DOWNLOAD_RESUME=yes
MODULE_PROMPTFILE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_PROMPTFILE_DOWNLOAD_SUCCESSIVE_INTERVAL=
MODULE_PROMPTFILE_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=

MODULE_PROMPTFILE_PROBE_OPTIONS=""

# Output a promptfile.com download URL
# $1: cookie file
# $2: promptfile url
# stdout: real file download link
promptfile_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.promptfile.com'
    local PAGE CHASH FILE_URL_POINTER FILE_URL FILE_NAME

    PAGE=$(curl -c "$COOKIE_FILE" --location "$URL") || return

    if match 'The file you requested does not exist or has been removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    CHASH=$(grep_form_by_order "$PAGE" 1 | \
        parse_form_input_by_name 'chash') || return

    PAGE=$(curl -c "$COOKIE_FILE" --location \
        --data "chash=$CHASH" "$URL") || return

    if match '+"player\.swf"' "$PAGE"; then
        FILE_URL_POINTER=$(parse 'url: ' '\(http.*\).,' <<< "$PAGE") || return
    else
        FILE_URL_POINTER=$(parse_attr 'download_btn.>' 'href' <<< "$PAGE") || return
    fi

    FILE_URL=$(curl --include "$FILE_URL_POINTER" | \
        grep_http_header_location) || return

    FILE_NAME=$(parse_attr 'span' 'title' <<< "$PAGE")

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: promptfile.com url
# $3: requested capability list
# stdout: 1 capability per line
promptfile_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl --location "$URL") || return

    # Got sometimes: HTTP/1.1 504 Gateway Time-out
    [ -z "$PAGE" ] && return $ERR_NETWORK

    if match 'The file you requested does not exist or has been removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    # There is only one <span> tag in the entire page!
    if [[ $REQ_IN = *f* ]]; then
        parse_attr 'span' 'title' <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'span' '(\([[:digit:].]\+[[:space:]]*[KMG]B\))' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
