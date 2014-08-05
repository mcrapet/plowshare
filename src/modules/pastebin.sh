# Plowshare pastebin.com module
# Copyright (c) 2013 Plowshare team
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

MODULE_PASTEBIN_REGEXP_URL='http://\(www\.\)\?pastebin\.com/'

MODULE_PASTEBIN_LIST_OPTIONS="
COUNT,,count,n=COUNT,Take COUNT pastes when listing user folder. Default is 100 (first web page)."
MODULE_PASTEBIN_LIST_HAS_SUBFOLDERS=no

# Static function. Process a single note
# $1: pastebin url
pastebin_single_list() {
    local URL=$1
    local PAGE LINKS

    if [ "${URL:0:1}" = '/' ]; then
        URL="http://pastebin.com/raw.php?i=${URL#/}"
    elif match '/[[:alnum:]]\+$' "$URL"; then
        URL=$(echo "$URL" | replace 'pastebin.com/' 'pastebin.com/raw.php?i=')
    elif ! match 'raw\.php?i=' "$URL"; then
        log_error 'Bad link format'
        return $ERR_FATAL
    fi

    PAGE=$(curl "$URL") || return
    LINKS=$(parse_all . '\(https\?://[^[:space:]]\+\)' <<< "$PAGE") || return

    # TODO: filter crappy links (length <15 chars, ...)

    list_submit "$LINKS"
}

# List all links in a pastebin note
# $1: pastebin url
# stdout: list of links
pastebin_list() {
    local -r URL=${1%/}
    local PASTES PASTE

    # User folder:
    # - http://pastebin.com/u/username
    if match '/u/[[:alnum:]]\+$' "$URL"; then
        local HTML
        HTML=$(curl "$URL") || return

        if [ -n "$COUNT" ]; then
            if (( COUNT > 100 )); then
                COUNT=100
                log_error "Too big integer value for --count, set it to $COUNT"
            fi
        else
            COUNT=100
        fi

        log_debug "user folder: listing first $COUNT items (if available)"
        PASTES=$(parse_all_attr 'title=.Public paste' href <<< "$HTML" | \
            first_line $COUNT) || return
    else
        PASTES=$URL
    fi

    # Accepted link format
    # - /xyz
    # - http://pastebin.com/xyz
    # - http://pastebin.com/raw.php?i=xyz
    while IFS= read -r PASTE; do
        pastebin_single_list "$PASTE" || continue
    done <<< "$PASTES"
}
