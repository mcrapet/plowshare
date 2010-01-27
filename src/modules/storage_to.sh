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

MODULE_STORAGE_TO_REGEXP_URL="^http://\(www\.\)\?storage.to/get/"
MODULE_STORAGE_TO_DOWNLOAD_OPTIONS=""
MODULE_STORAGE_TO_UPLOAD_OPTIONS=""
MODULE_STORAGE_TO_DOWNLOAD_CONTINUE=no

# Output an storage.to file download URL (anonymous, NOT PREMIUM)
#
# storage_to_download STORAGE_TO_URL
#
storage_to_download() {
    set -e
    eval "$(process_options storage_to "$MODULE_STORAGE_TO_DOWNLOAD_OPTIONS" "$@")"

    MAIN_PAGE=$(curl "$1?language=en")

    $(match 'File not found' "$MAIN_PAGE") && \
        { error "file not found"; return 254; }

    test "$CHECK_LINK" && return 255

    PARAMS_URL=${1/\/get\//\/getlink\/}

    while retry_limit_not_reached || return 3; do
        DATA=$(curl --location "$PARAMS_URL")

        # Parse JSON object
        # new Object({ 'state' : 'ok', 'countdown' : 60, 'link' : 'http://...', 'linkid' : 'Be5CAkz2' })
        # new Object({ 'state' : 'wait', 'countdown' : 2554, 'link' : '', 'linkid' : 'Be5CAkz2' })

        local state=$(echo "$DATA" | parse 'new Object' "'state'[[:space:]]*:[[:space:]]*'\([^']*\)'" 2>/dev/null)
        local count=$(echo "$DATA" | parse 'new Object' "'countdown'[[:space:]]*:[[:space:]]*\([[:digit:]]*\)" 2>/dev/null)
        local  link=$(echo "$DATA" | parse 'new Object' "'link'[[:space:]]*:[[:space:]]*'\([^']*\)'" 2>/dev/null)

        if [ $state == "ok" ]
        then
            countdown $((count+1)) 10 seconds 1 || return 2
            break
        elif [ $state == "wait" ]
        then
            debug "Download limit reached!"
            countdown $((count+1)) 60 seconds 1 || return 2
            continue
        else
            error "failed state ($state)"
            return 1
        fi
    done

    echo $link
}
