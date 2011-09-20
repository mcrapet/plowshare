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

# Solve usershare download javascript eval() that sets DATE value
usershare_download_solve() {
    PAGE=$(cat)
    # parts are '691ed77c|08977b85|ba207845|7d35eee8'
    PARTS=$(echo "$PAGE" | parse_quiet 'window|' "window|\([^']*\)")
    for I in 1 2 3 4; do
        P[$I]=$(echo "$PARTS" | cut -d\| -f$I)
    done
    # vars are 'i3|i6|i5|i4'
    VARS=$(echo "$PAGE" | parse_quiet 'var|' 'var|\([^|]*|[^|]*|[^|]*|[^|]*\)')
    for I in 1 2 3 4; do
        V[$I]=$(echo "$VARS" | cut -d\| -f$I)
    done
    # solution is i4+i5+i6+i3 with i3="7d35eee8", i4="ba207845", i5="08977b85", i6="691ed77c"
    J=4
    for I in 1 2 3 4; do
        echo "${V[$I]}"
    done |sort |while read K; do
        case "$K" in
            ${V[1]}) X[1]=${P[$J]}; (( J-- )) ;;
            ${V[2]}) X[2]=${P[$J]}; (( J-- )) ;;
            ${V[3]}) X[3]=${P[$J]}; (( J-- )) ;;
            ${V[4]}) X[4]=${P[$J]}; (( J-- )) ;;
        esac
        if [ $J -eq 0 ]; then
            for I in 4 3 2 1; do
                echo -n "${X[$I]}"
            done
            echo
        fi
    done
}

# Output an usershare file download URL (anonymous)
# $1: cookie file
# $2: usershare url
# stdout: real file download link
usershare_download() {
    eval "$(process_options usershare "$MODULE_USERSHARE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL="$2"

    # valid links: /<fileid> or /user/<fileid>
    local ID=$(echo "$URL" | parse_quiet '\/' '\/\([^/]*\)')
    if ! test "$ID"; then
        log_error "Cannot parse URL to extract file id (mandatory)"
        return 1
    fi

    URL="http://www.usershare.net/$ID"

    while retry_limit_not_reached || return; do
        PAGE=$(curl -c "$COOKIEFILE" "$URL") || return 1

        if match 'Reason for deletion' "$PAGE"; then
            log_debug "File not found"
            return $ERR_LINK_DEAD
        fi

        test "$CHECK_LINK" && return 0

        if match 'You have to wait' "$PAGE"; then
            log_debug "time limit, you must wait"

            # You have to wait 18 minutes, 3 seconds till next download
            WAIT_H=$(echo "$PAGE" | parse_quiet 'have to wait' ' \([0-9]\+\) hour')   || WAIT_H=0
            WAIT_M=$(echo "$PAGE" | parse_quiet 'have to wait' ' \([0-9]\+\) minute') || WAIT_M=0
            WAIT_S=$(echo "$PAGE" | parse_quiet 'have to wait' ' \([0-9]\+\) second') || WAIT_S=0

            wait $((WAIT_H * 3600 + WAIT_M * 60 + WAIT_S)) seconds || return
            continue
        fi

        # for some files (such as .mp3) we have direct link
        if match 'download_btn' "$PAGE"; then
            FILENAME=$(echo "PAGE" | parse_quiet '<h3>Download File:' '<h3>Download File:\([^<]\+\)<\/h3>')
            FILE_URL=$(echo "$PAGE" | parse_attr 'download_btn' 'href') || return 1

        else
            OP=$(echo "$PAGE" | parse_attr 'name="op"' "value") || return 1
            USR_LOGIN=$(echo "$PAGE" | parse_attr_quiet 'name="usr_login"' 'value') || USR_LOGIN=""
            FILENAME=$(echo "$PAGE" | parse_attr 'name="fname"' 'value')
            REFERER=$(echo "$PAGE" | parse_attr_quiet 'name="referer"' 'value') || REFERER=""
            METHOD_FREE=$(echo "$PAGE" | parse_attr 'name="method_free"' 'value')

            # there's some obfuscated eval() javascript that sets the DATE variable
            # Solution 1: interpret it and instead of modifying 'date' field, get the value
            #JS=$({ echo "print("; echo "$PAGE" | parse 'eval(' 'eval(\(.*\))'; echo ")"; } | javascript)
            #DATE=$(echo "$JS" | replace "window.document.getElementById('date').value=" 'print(' | replace '"";' '"");' | javascript)
            # Solution 2: bash implementation, more portable (but keep previous solution in case it changes)
            DATE=$(echo "$PAGE" | usershare_download_solve)

            DATA="op=$OP&usr_login=$USR_LOGIN&id=$ID&fname=$FILENAME&referer=$REFERER=&date=$DATE&method_free=$METHOD_FREE"
            PAGE2=$(curl -b "$COOKIEFILE" --referer "$URL" --data "$DATA" "$URL") || return

            # it happens when DATE or other params are incorrect
            if match 'User Login' "$PAGE2"; then
                log_error 'Failed to send proper parameters: page asks for login'
                return 1
            fi

            RAND=$(echo "$PAGE2" | parse_attr 'name="rand"' 'value') || return 1
            DATA="op=download2&id=$ID&rand=$RAND&referer=$URL&method_free=Slow Speed Download"
            PAGE3=$(curl -i -b "$COOKIEFILE" --referer "$URL" --data "$DATA" "$URL") || return 1

            FILE_URL=$(echo "$PAGE3" | grep_http_header_location) || return 1
        fi

        echo "$FILE_URL"
        test -n  "$FILENAME" && echo "$FILENAME"
        break
    done
}
