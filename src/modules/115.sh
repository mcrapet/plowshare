# Plowshare 115.com module
# Copyright (c) 2010-2012 Plowshare team
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

MODULE_115_REGEXP_URL='http://\([[:alnum:]]\+\.\)\?115\.com/file/'

MODULE_115_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)"
MODULE_115_DOWNLOAD_RESUME=no
MODULE_115_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_115_DOWNLOAD_SUCCESSIVE_INTERVAL=

# Output a 115.com file download URL
# $1: cookie file
# $2: 115.com url
# stdout: real file download link
115_download() {
    local COOKIEFILE=$1
    local URL=$2
    local PAGE JSON LINKS HEADERS DIRECT FILENAME U1 U2

    if [ -z "$AUTH" ]; then
        log_error 'Anonymous users cannot download links'
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    LOGIN_DATA=$(echo \
        'login[account]=$USER&login[passwd]=$PASSWORD&back=http%3A%2F%2Fwww.115.com&goto=http%3A%2F%2F115.com' | uri_encode)
    post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" 'http://passport.115.com/?ac=login' '-L' >/dev/null || return

    PAGE=$(curl -L -b "$COOKIEFILE" "$URL" | break_html_lines) || return

    if matchi "file_size:[[:space:]]*'0B'," "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    U1=$(echo "$PAGE" | parse_all 'url:' "'\(/?ct=download[^']*\)" | last_line) || return
    U2=$(echo "$PAGE" | parse 'GetMyDownloadAddress(' "('\([^']*\)") || return


    # {"state":true,"urls":[{"client":1,"url":"http:\/\/119. ...
    JSON=$(curl -b "$COOKIEFILE" "http://115.com$U1$U2") || return

    if ! match_json_true state "$JSON"; then
        log_error 'Bad state. Site updated?'
        return $ERR_FATAL
    fi

    LINKS=$(echo "$JSON" | parse_json 'url' split) || return

    # There are usually mirrors (do a HTTP HEAD request to check dead mirror)
    while read URL; do
        HEADERS=$(curl -I "$URL") || return

        FILENAME=$(echo "$HEADERS" | grep_http_header_content_disposition)
        if [ -n "$FILENAME" ]; then
            echo "$URL"
            echo "$FILENAME"
            return 0
        fi

        DIRECT=$(echo "$HEADERS" | grep_http_header_content_type) || return
        if [ "$DIRECT" = 'application/octet-stream' ]; then
            echo "$URL"
            return 0
        fi
    done <<< "$LINKS"

    log_debug 'all mirrors are dead'
    return $ERR_FATAL
}
