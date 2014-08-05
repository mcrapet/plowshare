# Plowshare zalil.ru module
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

MODULE_ZALIL_RU_REGEXP_URL='http://\(www\.\)\?zalil\.ru/'

MODULE_ZALIL_RU_DOWNLOAD_OPTIONS=""
MODULE_ZALIL_RU_DOWNLOAD_RESUME=yes
MODULE_ZALIL_RU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_ZALIL_RU_DOWNLOAD_SUCCESSIVE_INTERVAL=
MODULE_ZALIL_RU_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=(-H 'Connection: Keep-Alive')

MODULE_ZALIL_RU_UPLOAD_OPTIONS=""
MODULE_ZALIL_RU_UPLOAD_REMOTE_SUPPORT=no

MODULE_ZALIL_RU_PROBE_OPTIONS=""

# Output a zalil.ru file download URL
# $1: cookie file (unused here)
# $2: zalil.ru url
# stdout: real file download link
zalil_ru_download() {
    local -r URL=$2
    local PAGE FILE_URL JS

    # Content-Type: text/html; charset=windows-1251
    PAGE=$(curl -H 'Connection: Keep-Alive' "$URL") || return
    PAGE=${PAGE//$'\r'}

    if ! match '/page/abuse\?id=\|var[[:space:]]link' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    detect_javascript || return

    # Take "l1nk", not "link"
    JS=$(grep_script_by_order "$PAGE" 3) || return
    JS=$(echo "$JS" | delete_first_line | delete_last_line)
    log_debug "js: \"$JS\""

    FILE_URL=$(javascript <<< "$JS print(l1nk);") || return

    echo "http://zalil.ru$FILE_URL"
}

# Upload a file to zalil.ru
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
zalil_ru_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://www.zalil.ru/upload/'
    local PAGE SZ

    local -r MAX_SIZE=52428800 # 50 MiB
    SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Note: Use cookie to forward PHPSESSID for second (redirection) page
    PAGE=$(curl_with_log -c "$COOKIE_FILE" -L \
        -F "file=@$FILE;filename=$DESTFILE" \
        "$BASE_URL") || return

    parse_tag 'zalil\.ru/[[:digit:]]\+' div <<< "$PAGE"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: zalil.ru url
# $3: requested capability list
# stdout: 1 capability per line
zalil_ru_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -H 'Connection: Keep-Alive' "$URL") || return

    if ! match '/page/abuse\?id=\|var[[:space:]]link' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '^<p[[:space:]].*"center"' '^\(.\+\)&nbsp;' \
            1 <<< "$PAGE" | replace_all '&nbsp;' '' && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '^<p[[:space:]].*"center"' '&nbsp;\([^<]\+\)' 1 <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
