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
# Contributed by Matthieu Crapet

MODULE_UPLOADED_TO_REGEXP_URL="http://\(www\.\)\?\uploaded\.to/"
MODULE_UPLOADED_TO_DOWNLOAD_OPTIONS=""
MODULE_UPLOADED_TO_UPLOAD_OPTIONS=""
MODULE_UPLOADED_TO_DOWNLOAD_CONTINUE=no

# Output an uploaded.to file download URL (anonymous, NOT PREMIUM)
#
# uploaded_to_download UPLOADED_TO_URL
#
uploaded_to_download() {
    set -e
    eval "$(process_options uploaded_to "$MODULE_UPLOADED_TO_DOWNLOAD_OPTIONS" "$@")"

    # Create temporary file to store HTTP protocol headers
    HEADERS=$(create_tempfile ".tmp")
    HEADERS_KEY="^[Ll]ocation:[[:space:]]\+\/"

    while true; do  
        DATA=$(curl -L -D "$HEADERS" "$1")
 
        # Location: /?view=error_fileremoved   
        if test -n "$(cat "$HEADERS" | parse $HEADERS_KEY '\(error_fileremoved\)' 2>/dev/null)"
        then
            rm -f $HEADERS
 
            test -z $(match '\(premium account\|Premiumaccount\)' "$DATA") && \
                debug "premium user link only" || \
                debug "file not found"
            return 254

        # Location: /?view=error_traffic_exceeded_free&id=abcdef
        elif test -n "$(cat "$HEADERS" | parse $HEADERS_KEY '\(error_traffic_exceeded_free\)' 2>/dev/null)"
        then
            LIMIT=$(echo "$DATA" | parse "\(minutes\|minuti\|Minuten\)" '[[:space:]]\+\([[:digit:]]\+\)[[:space:]]\+') ||
                { error "can't get wait delay"; return 1; }

            debug "download limit reached: waiting $LIMIT minutes"
            sleep $(($LIMIT * 60))

        else
            local file_url=$(echo "$DATA" | parse "download_form" 'action="\([^"]*\)"')
            SLEEP=$(echo "$DATA" | parse "var[[:space:]]\+secs" "=[[:space:]]*\([[:digit:]]\+\);") ||
                { debug "ignore sleep time"; SLEEP=0; }

            test "$CHECK_LINK" && return 255

            debug "URL File: $file_url" 
            local file_real_name=$(echo "$DATA" | parse '<title>'  '>\(.*\) ... at uploaded.to') && \
            debug "Filename: $file_real_name"
            debug "waiting $SLEEP seconds"
            sleep $(($SLEEP + 1))
            break
        fi
    done

    rm -f $HEADERS

    # Example of URL:
    # http://s30b0-cb.uploaded.to/dl?id=12391efd1619c525cfe0c25175731572
    # Real filename is also stored in "Content-Disposition" HTTP header
 
    echo $file_url
    echo $file_real_name
}
