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
MODULE_DEPOSITFILES_DOWNLOAD_OPTIONS="
CHECK_LINK,c,check-link,,Check if a link exists and return"
MODULE_DEPOSITFILES_DOWNLOAD_CONTINUE=no

# Output a depositfiles file download URL (anonymous, NOT PREMIUM)
#
# depositfiles_download DEPOSITFILES_URL
#
depositfiles_download() {
    set -e
    eval "$(process_options depositfiles "$MODULE_DEPOSITFILES_DOWNLOAD_OPTIONS" "$@")"
    URL=$1
    
    BASEURL="depositfiles.com"
    while true; do        
        START=$(curl -L "$URL")
        echo "$START" | grep -q "no_download_msg" &&
            { debug "file not found"; return 1; }
        test "$CHECK_LINK" && return 255
        if echo "$START" | grep -q "download_started"; then
            echo "$START" | parse "download_started" 'action="\([^"]*\)"'
            return
        fi
        check_ip "$START" && continue    
        WAIT_URL=$(echo "$START" | grep "files/" \
                | parse '<form' 'action="\([^"]*\)"') ||
            { error "download form not found"; return 1; }
        test "$CHECK_LINK" && return 255
        DATA=$(curl --data "gateway_result=1" "${BASEURL}${WAIT_URL}") ||
            { error "can't get wait URL contents"; return 1; }
        LIMITM=$(echo "$DATA" | grep -A1 "try in" | \
            parse 'minute' '\([[:digit:]]\+\) minute' 2>/dev/null) || true
        if test "$LIMITM"; then
            debug "limit reached, wait $LIMITM minutes"
            sleep $((LIMITM*60))
            continue 
        fi
        LIMITS=$(echo "$DATA" | grep -A1 "try in" | \
            parse 'minute' '\([[:digit:]]\+\) second' 2>/dev/null) || true
        if test "$LIMITS"; then
            debug "limit reached, wait $LIMITS seconds"
            sleep $LIMITS
            continue 
        fi
        check_ip "$DATA" && continue
        break
    done
    FILE_URL=$(echo "$DATA" | parse "download_started" 'action="\([^"]*\)"') 
    SLEEP=$(echo "$DATA" | parse "download_waiter_remain" ">\([[:digit:]]\+\)<") ||
        { error "cannot get wait time"; return 1; }
    debug "URL File: $FILE_URL" 
    debug "waiting $SLEEP seconds" 
    sleep $(($SLEEP + 1))
    echo $FILE_URL    
}

check_ip() {
    if echo "$1" | grep -q '<div class="ipbg">'; then
        WAIT=60
        debug "IP already downloading, waiting $WAIT seconds"
        sleep $WAIT
        return 0
    else
        return 1
    fi
}
