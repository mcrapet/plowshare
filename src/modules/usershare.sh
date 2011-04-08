#!/bin/bash
#
# usershare.net module
# Copyright (c) 2010-2011 Plowshare team
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

MODULE_USERSHARE_REGEXP_URL="http://\(www\.\)\?usershare\.net/"
MODULE_USERSHARE_DOWNLOAD_OPTIONS=""
MODULE_USERSHARE_DOWNLOAD_CONTINUE=no

# Output a usershare file download URL
#
# $1: A usershare URL
#
usershare_download() {
    set -e
    eval "$(process_options usershare "$MODULE_USERSHARE_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    FILE_URL=$(curl "$URL" | parse_attr 'download_btn\.jpg' 'href' 2>/dev/null) ||
        { log_debug "file not found"; return 254; }

    test "$CHECK_LINK" && return 255

    echo "$FILE_URL"
}
