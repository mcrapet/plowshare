#!/bin/bash
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
#

MODULE_DEPOSITFILES_REGEXP_URL="http://\(\w\+\.\)\?depositfiles.com/"
MODULE_DEPOSITFILES_DOWNLOAD_OPTIONS=""
MODULE_DEPOSITFILES_UPLOAD_OPTIONS=
MODULE_DEPOSITFILES_DOWNLOAD_CONTINUE=no

# Output a depositfiles file download URL (free download)
#
# depositfiles_download DEPOSITFILES_URL
#
depositfiles_download() {
    set -e
    eval "$(process_options depositfiles "$MODULE_DEPOSITFILES_DOWNLOAD_OPTIONS" "$@")"
    URL=$1

    BASEURL="depositfiles.com"
    while retry_limit_not_reached || return 3; do
        START=$(curl -L "$URL")
        echo "$START" | grep -q "no_download_msg" &&
            { log_debug "file not found"; return 254; }
        test "$CHECK_LINK" && return 255
        if echo "$START" | grep -q "download_started"; then
            echo "$START" | parse "download_started" 'action="\([^"]*\)"'
            return
        fi
        check_ip "$START" || continue
        WAIT_URL=$(echo "$START" | grep "files/" \
                | parse '<form' 'action="\([^"]*\)"') ||
            { log_error "download form not found"; return 1; }
        test "$CHECK_LINK" && return 255
        DATA=$(curl --data "gateway_result=1" "${BASEURL}${WAIT_URL}") ||
            { log_error "can't get wait URL contents"; return 1; }
        check_wait "$DATA" "minute" "60" || continue
        check_wait "$DATA" "second" "1" || continue
        check_ip "$DATA" || continue
        break
    done
    FILE_URL=$(echo "$DATA" | parse "download_started" 'action="\([^"]*\)"')
    SLEEP=$(echo "$DATA" | parse "download_waiter_remain" ">\([[:digit:]]\+\)<") ||
        { log_error "cannot get wait time"; return 1; }

    # usual wait time is 60 seconds
    countdown $((SLEEP + 1)) 2 seconds 1 || return 2

    echo $FILE_URL
}

check_wait() {
    local HTML=$1
    local WORD=$2
    local FACTOR=$3
    LIMIT=$(echo "$HTML" | grep -A1 "try in" | \
        parse "$WORD" "\(\<[[:digit:]]\+\>\) $WORD" 2>/dev/null) || true
    if test "$LIMIT"; then
        log_debug "limit reached, waiting $LIMIT ${WORD}s"
        sleep $((LIMIT*FACTOR))
        return 1
    else
        return 0
    fi
}

check_ip() {
    if echo "$1" | grep -q '<div class="ipbg">'; then
        local WAIT=60
        log_debug "IP already downloading, waiting $WAIT seconds"
        sleep $WAIT
        return 1
    else
        return 0
    fi
}
