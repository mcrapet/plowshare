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

MODULE_UPLOADED_TO_REGEXP_URL="^http://\(www\.\)\?\(uploaded.to\|ul\.to\)/"
MODULE_UPLOADED_TO_DOWNLOAD_OPTIONS=""
MODULE_UPLOADED_TO_UPLOAD_OPTIONS=
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

    while retry_limit_not_reached || return 3; do
        DATA=$(curl --location --dump-header "$HEADERS" "$1")
        HEADER_LOC=$(cat "$HEADERS" | grep_http_header_location)

        # Location: /?view=error_fileremoved
        if match '\(error_fileremoved\)' "$HEADER_LOC"
        then
            rm -f $HEADERS

            $(match '\(premium account\|Premiumaccount\)' "$DATA") && \
                debug "premium user link only" || \
                debug "file not found"
            return 254

        # Location: /?view=error_traffic_exceeded_free&id=abcdef
        elif match '\(error_traffic_exceeded_free\)' "$HEADER_LOC"
        then
            LIMIT=$(echo "$DATA" | parse "\(minutes\|minuti\|Minuten\)" '[[:space:]]\+\([[:digit:]]\+\)[[:space:]]\+') ||
                { error "can't get wait delay"; return 1; }

            debug "Download limit reached!"
            countdown $LIMIT 1 minutes 60 || return 2

        # Location: /?view=error2&id_a=xxx&id_b=yyy
        elif match '\(error[[:digit:]]\)' "$HEADER_LOC"
        then
            rm -f $HEADERS
            debug "internal error"
            return 1

        else
            local file_url=$(echo "$DATA" | parse "download_form" 'action="\([^"]*\)"')
            SLEEP=$(echo "$DATA" | parse "var[[:space:]]\+secs" "=[[:space:]]*\([[:digit:]]\+\);") ||
                { debug "ignore sleep time"; SLEEP=0; }

            test "$CHECK_LINK" && return 255

            local file_real_name=$(echo "$DATA" | parse '<title>' '>\(.*\) ... at uploaded.to' 2>/dev/null)

            # in title, filename is truncated to 60 characters
            if [ "${#file_real_name}" -eq 60 ]
            then
                local file_real_name_ext=$(echo "$DATA" | parse '[[:space:]]\+' "[[:space:]]\+\(${file_real_name}[^ ]*\)" 2>/dev/null)
                local extension=$(echo "$DATA" | parse 'Filetype' '<\/td><td>\([^<]*\)<\/td><\/tr>' 2>/dev/null)

                # a part of extension is present in the 60 characters string
                if [ -z "$file_real_name_ext" ]; then
                    file_real_name_ext=$(echo "$DATA" | \
                            parse '[[:space:]]\+' "[[:space:]]\+\(${file_real_name%.*}[^ ]*\)" 2>/dev/null)
                fi

                [ -n "$file_real_name_ext" ] && file_real_name="${file_real_name_ext}${extension}"
            fi

            # usual wait time is 12 seconds
            countdown $((SLEEP + 1)) 2 seconds 1 || return 2
            break
        fi
    done

    rm -f $HEADERS

    # Example of URL:
    # http://s30b0-cb.uploaded.to/dl?id=12391efd1619c525cfe0c25175731572
    # Real filename is also stored in "Content-Disposition" HTTP header

    echo $file_url
    test -n "$file_real_name" && echo "$file_real_name"
    return 0
}
