# Plowshare embedupload.com module
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

MODULE_EMBEDUPLOAD_REGEXP_URL='http://\(www\.\)\?embedupload\.com/'

MODULE_EMBEDUPLOAD_LIST_OPTIONS=""
MODULE_EMBEDUPLOAD_LIST_HAS_SUBFOLDERS=no

# List links from an embedupload link
# $1: embedupload link
# $2: recurse subfolders (ignored here)
# stdout: list of links
embedupload_list() {
    local URL=$1
    local PAGE LINKS LINK NAME

    local -r NOT_AUTHORIZED_PATTERN='not authorized'

    if matchi 'embedupload.com/?d=' "$URL"; then
        # Handle folders: get all URLs in there and resolve them
        PAGE=$(curl "$URL") || return
        LINKS=$(parse_all_attr 'class=.DownloadNow.' href <<< "$PAGE") || return

        NAME=$(parse 'class=.form-title.' '^[[:space:]]*\([^<]\+\)' 1 <<< "$PAGE")
        NAME=${NAME% }

    # Sub-link
    elif matchi 'embedupload.com/?[[:alpha:]][[:alpha:]]=' "$URL"; then
        LINKS=$URL
        NAME=$(parse_quiet . '?\(..\)=' <<< "$URL")
    else
        log_error 'Bad link format'
        return $ERR_FATAL
    fi

    for URL in $LINKS; do
        PAGE=$(curl "$URL" | strip_html_comments) || return

        # You should click on the download link
        LINK=$(parse_tag 'target=' a <<< "$PAGE") || continue

        # Ignore URLs we are not authorized for
        if ! matchi "$NOT_AUTHORIZED_PATTERN" "$LINK"; then
            echo "$LINK"
            echo "$NAME"
        fi
    done
}
