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

MODULE_X7_TO_REGEXP_URL="^http://\(www\.\)\?x7.to/"
MODULE_X7_TO_DOWNLOAD_OPTIONS=""
MODULE_X7_TO_UPLOAD_OPTIONS=""
MODULE_X7_TO_DOWNLOAD_CONTINUE=no

# Output an x7.to file download URL (anonymous, NOT PREMIUM)
#
# x7_to_download X7_TO_URL
#
x7_to_download() {
    set -e
    eval "$(process_options x7_to "$MODULE_X7_TO_DOWNLOAD_CONTINUE" "$@")"

    URL=$1
    BASE_URL="http://x7.to"
    COOKIES=$(create_tempfile)

    while retry_limit_not_reached || return 3; do
        WAIT_HTML=$(curl -L -c $COOKIES "$URL")

        local ref_fid=$(echo $WAIT_HTML | parse 'document.cookie[[:space:]]=[[:space:]]*' 'ref_file=\([^&]*\)' 2>/dev/null)

        if [ -z "$ref_fid" ]; then
            $(match '\([Ff]ile not found\)' "$WAIT_HTML") &&
                error "File not found"

            if $(match '\(<span id="foldertitle">\)' "$WAIT_HTML")
            then
                local textlist=$(echo "$WAIT_HTML" | parse 'listplain' '<a href="\([^"]*\)' 2>/dev/null)
                error "This is a folder list (check $BASE_URL/$textlist)"
            fi

            return 254
        fi

        test "$CHECK_LINK" && return 255

        file_real_name=$(echo "$WAIT_HTML" | parse '<span style="text-shadow:#5855aa 1px 1px 2px">' '>\([^<]*\)<small' 2>/dev/null)
        extension=$(echo "$WAIT_HTML" | parse '<span style="text-shadow:#5855aa 1px 1px 2px">' '<small[^>]*>\([^<]*\)<\/small>' 2>/dev/null)
        file_real_name="$file_real_name$extension"

        # according to http://x7.to/js/download.js
        DATA=$(curl -b $COOKIES "$BASE_URL/james/ticket/dl/$ref_fid")

        # Parse JSON object
        # {type:'download',wait:12,url:'http://stor2.x7.to/dl/Z5H3o51QqB'}
        # {err:"Download denied."}

        local type=$(echo "$DATA" | parse '^' "type[[:space:]]*:[[:space:]]*'\([^']*\)" 2>/dev/null)
        local wait=$(echo "$DATA" | parse '^' 'wait[[:space:]]*:[[:space:]]*\([[:digit:]]*\)' 2>/dev/null)
        local link=$(echo "$DATA" | parse '^' "url[[:space:]]*:[[:space:]]*'\([^']*\)" 2>/dev/null)

        if [ "$type" == "download" ]
        then
            countdown $((wait)) 1 seconds 1 || return 2
            break;
        elif $(match '\(limit-dl\)' "$DATA")
        then
            debug "Download limit reached!"
            WAITTIME=5
            countdown $((WAITTIME)) 1 minutes 60 || return 2
            continue
        else
            local error=$(echo "$DATA" | parse 'err:' '{err:"\([^"]*\)"}' 2>/dev/null)
            error "failed state [$error]"

            rm -f $COOKIES
            return 1
        fi
    done

    rm -f $COOKIES

    # Example of URL:
    # http://stor4.x7.to/dl/IMDju9Fk5y
    # Real filename is also stored in "Content-Disposition" HTTP header

    echo $link
    test -n "$file_real_name" && echo "$file_real_name"
    return 0
}
