# Plowshare anonfiles.com module
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

MODULE_ANONFILES_REGEXP_URL='https\?://\([[:alnum:]]\+\.\)\?anonfiles\.com/'

MODULE_ANONFILES_DOWNLOAD_OPTIONS=""
MODULE_ANONFILES_DOWNLOAD_RESUME=yes
MODULE_ANONFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_ANONFILES_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=()
MODULE_ANONFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_ANONFILES_UPLOAD_OPTIONS=""
MODULE_ANONFILES_UPLOAD_REMOTE_SUPPORT=no

MODULE_ANONFILES_PROBE_OPTIONS=""

# Output an AnonFiles.com file download URL
# $1: cookie file (unsued here)
# $2: anonfiles url
# stdout: real file download link
anonfiles_download() {
    local -r URL=$2
    local PAGE FILE_URL FILENAME

    PAGE=$(curl -L "$URL") || return

    if match '404 - File Not Found<\|>File does not exist\.<' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr_quiet 'download_button' href)

    if [ -z "$FILE_URL" ]; then
        FILE_URL=$(echo "$PAGE" | \
            parse_attr_quiet 'image_preview' src) || return
    fi


    FILENAME=$(echo "$PAGE" | parse_tag '<legend' b)

    # Mandatory!
    MODULE_ANONFILES_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=(--referer "$URL")

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to AnonFiles.com
# Use API: https://anonfiles.com/api/help
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download
anonfiles_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r API_URL='https://anonfiles.com/api/v1/'
    local JSON DL_URL ERR MSG

    # Note1: Accepted file types is very restrictive! According to site: jpg, jpeg, gif, png, pdf,
    #        css, txt, avi, mpeg, mpg, mp3, doc, docx, odt, apk, 7z, rmvb, zip, rar, mkv, xls.

    # Note2: -F "file_publish=on" does not work!
    JSON=$(curl_with_log \
        -F "file=@$FILE;filename=$DESTFILE" "${API_URL}upload") || return

    DL_URL=$(parse_json_quiet url <<< "$JSON")
    if match_remote_url "$DL_URL"; then
      echo "$DL_URL"
      return 0
    fi

    ERR=$(parse_json status <<< "$JSON")
    MSG=$(parse_json msg <<< "$JSON")
    log_error "Unexpected status ($ERR): $MSG"
    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: AnonFiles.com url
# $3: requested capability list
# stdout: 1 capability per line
anonfiles_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local -r API_URL='https://anonfiles.com/api/v1/'
    local FILE_ID JSON RET REQ_OUT

    FILE_ID=$(parse . '/\(.*\)$' <<< "$URL") || return
    JSON=$(curl "${API_URL}info/$FILE_ID") || return

    RET=$(parse_json status <<< "$JSON")
    if [ "$RET" -ne 0 ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_json_quiet 'file_name' <<< "$JSON" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        parse_json_quiet 'file_size' <<< "$JSON" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
