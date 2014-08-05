# Plowshare filebin.ca module
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

MODULE_FILEBIN_CA_REGEXP_URL='https\?://\(www\.\)\?filebin\.ca/[[:alnum:]]\+'

MODULE_FILEBIN_CA_DOWNLOAD_OPTIONS=""
MODULE_FILEBIN_CA_DOWNLOAD_RESUME=yes
MODULE_FILEBIN_CA_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FILEBIN_CA_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FILEBIN_CA_UPLOAD_OPTIONS=""
MODULE_FILEBIN_CA_UPLOAD_REMOTE_SUPPORT=no

MODULE_FILEBIN_CA_PROBE_OPTIONS=""

# Output a filebin.ca file download URL
# $1: cookie file (unused here)
# $2: filebin.ca url
# stdout: real file download link
filebin_ca_download() {
    local -r URL=$2

    # Nothing to do, links are direct!
    echo "$URL"
}

# Upload a file to filebin.ca
# Official sources: https://github.com/slepp/filebin.ca
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
filebin_ca_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://filebin.ca/upload.php'
    local DATA STATUS

    # No API key for now..
    DATA=$(curl_with_log \
        -F "file=@$FILE;filename=$DESTFILE" \
        "$BASE_URL") || return

    if [ -z "$DATA" ]; then
        log_error 'Remote error: empty result not expected. Server busy?'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Result sample:
    # status:wjBQjTib7TH
    # url:http://filebin.ca/wjBQjTib7TH/foo.zip
    STATUS=$(parse '^status:' '^status:\(.*\)' <<< "$DATA") || return
    if [ "$STATUS" = 'error' -o "$STATUS" = 'fail' ]; then
        log_error 'Remote error'
        return $ERR_FATAL
    fi

    parse '^url:' '^url:\(http://[^[:space:]]\+\)' <<< "$DATA"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: filebin.ca url
# $3: requested capability list
# stdout: 1 capability per line
filebin_ca_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local HEADERS REQ_OUT

    # Content-Type: application/octet-stream
    # Content-Disposition: attachment; filename="foo"
    # Content-length: 123456
    HEADERS=$(curl --head "$URL") || return

    if match '404 Not Found' "$HEADERS"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        grep_http_header_content_disposition <<< "$HEADERS" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        grep_http_header_content_length <<< "$HEADERS" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
