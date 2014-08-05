# Plowshare gfile.ru module
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

MODULE_GFILE_RU_REGEXP_URL='http://\(www\.\)\?gfile\.ru/'

MODULE_GFILE_RU_DOWNLOAD_OPTIONS=""
MODULE_GFILE_RU_DOWNLOAD_RESUME=yes
MODULE_GFILE_RU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_GFILE_RU_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_GFILE_RU_UPLOAD_OPTIONS=""
MODULE_GFILE_RU_UPLOAD_REMOTE_SUPPORT=no

MODULE_GFILE_RU_PROBE_OPTIONS=""

# Output a gfile.ru file download URL
# $1: cookie file (unused here)
# $2: gfile.ru url
# stdout: real file download link
gfile_ru_download() {
    local -r URL=$2
    local PAGE FILE_URL FILE_NAME

    PAGE=$(curl "$URL") || return

    if match '<h1>404</h1>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # Note: 'slink' seems to be an alternate link
    FILE_URL=$(parse '^"link"' ':"\([^"]\+\)' <<< "$PAGE") || return
    FILE_NAME=$(parse '^"title"' ':"\([^"]\+\)' <<< "$PAGE") || return

    echo "http://gfile.ru$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to gfile.ru
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
gfile_ru_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://www.gfile.ru/upload/'
    local PAGE SZ

    local -r MAX_SIZE=104857600 # 100 MiB
    SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Note: Use cookie to forward PHPSESSID for second (redirection) page
    PAGE=$(curl_with_log -c "$COOKIE_FILE" -L \
        -F "file=@$FILE;filename=$DESTFILE" \
        "$BASE_URL") || return

    parse_attr '=.link_container' value <<< "$PAGE"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: gfile.ru url
# $3: requested capability list
# stdout: 1 capability per line
gfile_ru_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl "$URL") || return

    if match '<h1>404</h1>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '^"title"' ':"\([^"]\+\)' <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '=.linkplace' '^[[:space:]]*\([^<]\+\)' 1 <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
