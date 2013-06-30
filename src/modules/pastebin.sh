#!/bin/bash
#
# pastebin.com module
# Copyright (c) 2011-2013 Plowshare team
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

MODULE_PASTEBIN_REGEXP_URL="http://\(www\.\)\?pastebin\.com/"

MODULE_PASTEBIN_LIST_OPTIONS=""

# List all links in pastebin file
# $1: pastebin url (http://pastebin.com/..., http://pastebin.com/raw.php?i=...)
# stdout: decrypted link
pastebin_list() {
    local URL=$1
    test "$2" && log_debug "recursive flag is not supported"

    local SOURCE PASTE LINKS

    if ! matchi 'raw.php?i=' "$URL"; then
        URL=$(echo "$URL" | replace "pastebin.com/" "pastebin.com/raw.php?i=")
    fi

    SOURCE=$(curl "$URL") || return
    LINKS=$(echo "$SOURCE" | parse_all '.' '\(https\?://[a-zA-Z0-9\-\.]\+\.[a-zA-Z]\{2,3\}\(\/[^[:space:]]*\)\?\)') || return

    for link in $LINKS; do
        echo "$link"
        echo
    done

    return 0
}

