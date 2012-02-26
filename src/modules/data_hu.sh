#!/bin/bash
#
# data.hu module
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

MODULE_DATA_HU_REGEXP_URL="http://\(www\.\)\?data.hu/get/"

MODULE_DATA_HU_DOWNLOAD_OPTIONS=""
MODULE_DATA_HU_DOWNLOAD_RESUME=yes
MODULE_DATA_HU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

# Output a data_hu file download URL
# $1: cookie file (unused here)
# $2: data.hu url
# stdout: real file download link
data_hu_download() {
    local URL=$2
    local PAGE

    PAGE=$(curl -L "$URL") || return

    if match "/missing.php" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_URL=$(echo "$PAGE" | \
        parse_attr 'download_box_button' 'href') || return

    test "$CHECK_LINK" && return 0

    echo "$FILE_URL"
}
