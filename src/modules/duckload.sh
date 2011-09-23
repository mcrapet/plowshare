#!/bin/bash
#
# duckload.com module
# Copyright (c) 2011 Plowshare team
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

MODULE_DUCKLOAD_REGEXP_URL="http://\(www\.\)\?duckload\.com/"

MODULE_DUCKLOAD_DOWNLOAD_OPTIONS=""
MODULE_DUCKLOAD_DOWNLOAD_RESUME=no
MODULE_DUCKLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

# Output DuckLoad download URL
# $1: cookie file (unused here)
# $2: duckload.com url
# stdout: real file download link
duckload_download() {
    local URL="$2"
    local BASE_URL="http://www.duckload.com/jDownloader"

    local URL_CHECKONLINESTATUS="$BASE_URL/checkOnlineStatus.php"
    local URL_GETFREE="$BASE_URL/getFree.php"
    local URL_GETFREEENCRYPT="$BASE_URL/getFreeEncrypt.php"

    log_debug "checking online status"
    STATUS=$(curl \
            --data-urlencode "isPremium=0" \
            --data-urlencode "list=$URL" "$URL_CHECKONLINESTATUS")

    log_debug "$STATUS"
    if matchi "ERROR;" "$STATUS" || matchi "OFFLINE" "$STATUS"
    then
        if matchi "OFFLINE" "$STATUS"
        then
            log_error "file not currently available"
            return $ERR_LINK_DEAD
        fi
    fi

    log_debug "getting free slots"
    STATUS=$(curl \
        --referer "$URL_CHECKONLINESTATUS" \
        --data-urlencode "link=$URL" "$URL_GETFREE")

    log_debug $STATUS
    if matchi "ERROR;" "$STATUS"; then
        log_error "error getting free download slot"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    WAIT_TIME=$(echo "$STATUS" | cut -d ";" -f 2 | strip)
    CRYPT=$(echo "$STATUS" | cut -d ";" -f 3 | strip)

    log_debug "free user delay "
    wait $WAIT_TIME || return

    log_debug "getting final url"
    STATUS=$(curl \
        --referer "$URL_GETFREE" \
        --data-urlencode "crypt=$CRYPT" "$URL_GETFREEENCRYPT")

    log_debug $STATUS
    if matchi "http" "$STATUS"; then
        log_debug "starting download: $STATUS"
        echo "$STATUS"
    else
        return $ERR_FATAL
    fi
}
