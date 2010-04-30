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

MODULE_X7_TO_REGEXP_URL="^http://\(www\.\)\?x7\.to/"
MODULE_X7_TO_DOWNLOAD_OPTIONS="
AUTH_FREE,b:,auth-free:,USER:PASSWORD,Use Free account"
MODULE_X7_TO_UPLOAD_OPTIONS=
MODULE_X7_TO_DOWNLOAD_CONTINUE=no

# Output an x7.to file download URL
#
# Usage: x7_to_download X7_TO_URL
# Options:
#   -b USER:PASSWORD, --auth-free=USER:PASSWORD
#
x7_to_download() {
    eval "$(process_options x7_to "$MODULE_X7_TO_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    BASE_URL="http://x7.to"
    COOKIES=$(create_tempfile)

    if [ -z "$AUTH_FREE" ]; then
        $(curl -c $COOKIES -o /dev/null "$URL")
    else
        # Do the secure HTTP login! Adding --referer is mandatory.
        LOGIN_DATA='id=$USER&pw=$PASSWORD'
        LOGIN_RESULT=$(post_login "$AUTH_FREE" "$COOKIES" "$LOGIN_DATA" \
                "${BASE_URL}/james/login" "--referer ${BASE_URL}") || {
            rm -f $COOKIES
            return 1
        }

        # {err:"Benutzer und Passwort stimmen nicht überein."}
        if match '^{err:' "$LOGIN_RESULT"; then
            log_error "login process failed"
            rm -f $COOKIES
            return 1
        fi
    fi

    while retry_limit_not_reached || return 3; do
        WAIT_HTML=$(curl -L -b $COOKIES "$URL")

        local ref_fid=$(echo "$WAIT_HTML" | parse 'document.cookie[[:space:]]=[[:space:]]*' \
                'ref_file=\([^&]*\)' 2>/dev/null)

        if [ -z "$ref_fid" ]; then
            matchi 'file not found' "$WAIT_HTML" &&
                log_error "File not found"

            if match '<span id="foldertitle">' "$WAIT_HTML"
            then
                local textlist=$(echo "$WAIT_HTML" | parse_attr 'listplain' 'href')
                log_error "This is a folder list (check $BASE_URL/$textlist)"
            fi

            rm -f $COOKIES
            return 254
        fi

        if test "$CHECK_LINK"; then
            rm -f $COOKIES
            return 255
        fi

        file_real_name=$(echo "$WAIT_HTML" | parse '<span style="text-shadow:#5855aa 1px 1px 2px">' \
                '>\([^<]*\)<small' 2>/dev/null)
        extension=$(echo "$WAIT_HTML" | parse '<span style="text-shadow:#5855aa 1px 1px 2px">' \
                '<small[^>]*>\([^<]*\)<\/small>' 2>/dev/null)
        file_real_name="$file_real_name$extension"

        # According to http://x7.to/js/download.js
        DATA=$(curl -b $COOKIES -b "cookie_test=enabled; ref=ref_user=6649&ref_file=${ref_fid}&url=&date=1234567890" \
                    --data-binary "" \
                    --referer "$URL" \
                    "$BASE_URL/james/ticket/dl/$ref_fid")

        # Parse JSON object
        # {type:'download',wait:12,url:'http://stor2.x7.to/dl/Z5H3o51QqB'}
        # {err:"Download denied."}

        local type=$(echo "$DATA" | parse '^' "type[[:space:]]*:[[:space:]]*'\([^']*\)" 2>/dev/null)
        local wait=$(echo "$DATA" | parse '^' 'wait[[:space:]]*:[[:space:]]*\([[:digit:]]*\)' 2>/dev/null)
        local link=$(echo "$DATA" | parse '^' "url[[:space:]]*:[[:space:]]*'\([^']*\)" 2>/dev/null)

        if [ "$type" == "download" ]
        then
            wait $((wait)) seconds || return 2
            break;
        elif match 'limit-dl\|limit-parallel' "$DATA"
        then
            log_debug "Download limit reached!"
            WAITTIME=5
            wait $((WAITTIME)) minutes || return 2
            continue
        else
            local error=$(echo "$DATA" | parse 'err:' '{err:"\([^"]*\)"}' 2>/dev/null)
            log_error "failed state [$error]"

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
