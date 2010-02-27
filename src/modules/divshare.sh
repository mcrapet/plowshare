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

MODULE_DIVSHARE_REGEXP_URL="http://\(www\.\)\?divshare\.com/download"
MODULE_DIVSHARE_DOWNLOAD_OPTIONS=""
MODULE_DIVSHARE_UPLOAD_OPTIONS=
MODULE_DIVSHARE_DOWNLOAD_CONTINUE=no

# Output a divshare file download URL
#
# $1: A divshare URL
#
divshare_download() {
    set -e
    eval "$(process_options divshare "$MODULE_DIVSHARE_DOWNLOAD_OPTIONS" "$@")"

    PAGE=$(curl "$1")
    FILE_URL=$(echo "$PAGE" | parse '\(download_message\|Download Original\)' \
            'href="\([^"]*\)"') ||
        { error "file not found"; return 254; }

    test "$CHECK_LINK" && return 255

    FILE_NAME=$(echo "$PAGE" | sed -n '/"file_name"/,/<\/div>/p' | tr -d "\n" |
            parse '">' '>[[:space:]]*\(.*\)[[:space:]]*<') ||
        { debug "can't parse filename, website updated?"; }

    # Real filename is also stored in "Content-Disposition" HTTP header
    # We are lucky here, we can make an extra http request without being accused of parallel download!
    if [ -z "$FILE_NAME" ]; then
        FILE_NAME=$(curl -I "$FILE_URL" | parse '^Content-Disposition:' 'filename="\(.*\)";')
    fi

    echo "$FILE_URL"
    test -n "$FILE_NAME" && echo "$FILE_NAME"
    return 0
}
