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

MODULE_FILEFACTORY_REGEXP_URL="http://\(www\.\)\?filefactory\.com/file"
MODULE_FILEFACTORY_DOWNLOAD_OPTIONS=""
MODULE_FILEFACTORY_UPLOAD_OPTIONS=
MODULE_FILEFACTORY_DOWNLOAD_CONTINUE=yes

# Output a filefactory file download URL (anonymous, NOT PREMIUM)
#
# filefactory_download FILEFACTORY_URL
#
filefactory_download() {
    set -e
    eval "$(process_options filefactory "$MODULE_FILEFACTORY_DOWNLOAD_OPTIONS" "$@")"

    BASE_URL="http://www.filefactory.com"
    HTML_PAGE=$(curl "$1")

    WAIT_URL=$(echo "$HTML_PAGE" | \
            parse_attr 'button\.basic\.jpg\|Download Now' 'href' 2>/dev/null) ||
        { error "file not found"; return 254; }

    test "$CHECK_LINK" && return 255

    HTML_PAGE=$(curl "${BASE_URL}${WAIT_URL}")

    WAIT_TIME=$(echo "$HTML_PAGE" | parse '<span class="countdown">' '>\([[:digit:]]*\)<\/span>')
    FILE_URL=$(echo "$HTML_PAGE" | parse_attr 'Download with FileFactory Basic' 'href' 2>/dev/null) ||
        { error "can't parse filename, website updated?"; return 1; }

    countdown $((WAIT_TIME)) 10 seconds 1

    echo $FILE_URL
}
