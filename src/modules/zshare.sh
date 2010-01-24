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
MODULE_ZSHARE_REGEXP_URL="^http://\(www\.\)\?zshare.net/download"
MODULE_ZSHARE_DOWNLOAD_OPTIONS=""
MODULE_ZSHARE_UPLOAD_OPTIONS=
MODULE_ZSHARE_DOWNLOAD_CONTINUE=yes

# Output a zshare file download URL
#
# zshare_download [MODULE_ZSHARE_DOWNLOAD_OPTIONS] URL
#
zshare_download() {
    set -e
    eval "$(process_options ZSHARE "$MODULE_ZSHARE_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    COOKIES=$(create_tempfile)

    WAITPAGE=$(curl -L -c $COOKIES --data "download=1" "$URL")
    echo "$WAITPAGE" | grep -q "File Not Found" &&
        { error "file not found"; return 254; }

    test "$CHECK_LINK" && return 255

    WAITTIME=$(echo "$WAITPAGE" | parse "document|important||here" \
        "||here|\([[:digit:]]\+\)")

    countdown $((WAITTIME)) 5 seconds 1 || return 2

    JSCODE=$(echo "$WAITPAGE" | grep "var link_enc")

    FILE_URL=$(echo "$JSCODE" "; print(link);" | js)
    FILENAME=$(echo "$WAITPAGE" |\
        parse '<h2>[Dd]ownload:' '<h2>[Dd]ownload:[[:space:]]*\([^<]*\)')

    echo $FILE_URL
    echo $FILENAME
    echo $COOKIES
}
