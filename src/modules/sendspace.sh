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

MODULE_SENDSPACE_REGEXP_URL="http://\(www\.\)\?sendspace.com/file/"
MODULE_SENDSPACE_DOWNLOAD_OPTIONS=""
MODULE_SENDSPACE_UPLOAD_OPTIONS=
MODULE_SENDSPACE_DOWNLOAD_CONTINUE=no

# Output a sendspace file download URL
#
# $1: A sendspace URL
#
sendspace_download() {
    set -e
    eval "$(process_options sendspace "$MODULE_SENDSPACE_DOWNLOAD_OPTIONS" "$@")"
    URL=$1

    FILE_URL=$(curl -L --data "download=1" "$URL" |
        parse 'spn_download_link' 'href="\([^"]*\)"' 2>/dev/null) ||
        { error "file not found"; return 254; }

    test "$CHECK_LINK" && return 255

    HOST=$(echo "$FILE_URL" | grep -o "^http://[^/]*")
    PATH=$(curl -I "$FILE_URL" | grep_http_header_location) || return 1

    echo "${HOST}${PATH}"
}
