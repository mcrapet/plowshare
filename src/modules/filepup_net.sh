# Plowshare filepup.net module
# Copyright (c) 2013-2014 Plowshare team
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

MODULE_FILEPUP_NET_REGEXP_URL='https\?://\(www\.\|sp[[:digit:]]\.\)\?filepup\.net/'

MODULE_FILEPUP_NET_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_FILEPUP_NET_DOWNLOAD_RESUME=no
MODULE_FILEPUP_NET_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_FILEPUP_NET_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=()
MODULE_FILEPUP_NET_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FILEPUP_NET_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
filepup_net_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE ERR TYPE NAME

    LOGIN_DATA='user=$USER&pass=$PASSWORD&submit=Login&task=dologin&return=.%2Fmembers%2Fmyfiles.php&Submit=Sign+In'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/loginaa.php" -L) || return

    if match '<div class="error">' "$PAGE"; then
        ERR=$(echo "$PAGE" | parse_tag 'class="error">' div)
        log_debug "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    NAME=$(parse 'class=.hue' '=.hue.>\([^<]\+\)</s' <<< "$PAGE") || NAME='?'
    TYPE=$(parse_tag_quiet 'fa-star.>' b <<< "$PAGE")

    # <span class="hue"> <i class="fa fa-star"></i><b>PRO MEMBER</b></span><br>
    if matchi 'FREE MEMBER' "$TYPE"; then
        TYPE='free'
    elif matchi 'PRO MEMBER' "$TYPE"; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    log_debug "Successfully logged in as $TYPE member (${NAME%\'s})"
    echo "$TYPE"
}

# Output a filepup.net file download URL
# $1: cookie file
# $2: filepup.net url
# stdout: real file download link
filepup_net_download() {
    local -r COOKIE_FILE=$1
    local URL=$(replace '/info/' '/files/' <<<"$2")
    local -r BASE_URL='http://www.filepup.net'
    local PAGE FILE_URL FILE_NAME ACCOUNT FORM_HTML FORM_TASK WAIT_TIME ERR HEADERS DIRECT

    # Get PHPSESSID cookie
    PAGE=$(curl -L -c "$COOKIE_FILE" "$URL") || return

    # You have been given the wrong link or the file you have requested has been deleted for a violation or for inactivity.
    #if match 'has been deleted' "$PAGE"; then
    #    return $ERR_LINK_DEAD
    #fi

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(filepup_net_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
        PAGE=$(curl -L -b "$COOKIE_FILE" "$URL") || return
    else
        ACCOUNT=anonymous
    fi

    if [ "$ACCOUNT" = 'premium' ]; then
        URL=$(echo "$PAGE" | parse '[[:space:]]PRO USER<' "location='\([^']\+\)" | uri_encode)
        [ -n "$URL" ] || \
            URL=$(echo "$PAGE" | parse '<button.*/get/' "location='\([^']\+\)" | uri_encode) || return

        HEADERS=$(curl -b "$COOKIE_FILE" -I "$URL") || return
        DIRECT=$(echo "$HEADERS" | grep_http_header_content_type) || return

        # Sometimes returns file at this point, maybe some sort of cache
        if [ "$DIRECT" = 'application/force-download' ]; then
            MODULE_FILEPUP_NET_DOWNLOAD_RESUME=yes
            echo "$URL"
            return 0
        fi
    else
        URL=$(echo "$PAGE" | parse '[[:space:]]FREE USER<' "location='\([^']\+\)" | uri_encode)
        [ -n "$URL" ] || \
            URL=$(echo "$PAGE" | parse '<button.*/get/' "location='\([^']\+\)" | uri_encode) || return
        FILE_NAME=$(echo "$PAGE" | parse '[[:space:]]text-overflow:' '>\([^<]\+\)</h') || return

        WAIT_TIME=$(echo "$PAGE" | parse \
            '^[[:space:]]*var time[[:space:]]*=' '=[[:space:]]*\([[:digit:]]\+\)') || return
        wait $((WAIT_TIME))
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

    # Sanity check
    if [ -z "$PAGE" ]; then
        log_error 'Remote server: empty answer. Your link may be outdated.'
        return $ERR_FATAL
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" -1) || return
    FILE_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_TASK=$(echo "$FORM_HTML" | parse_form_input_by_name 'task') || return

    if [ "$ACCOUNT" = 'premium' ]; then
        MODULE_FILEPUP_NET_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=(--data "task=$FORM_TASK")

    else
        # We expect HTTP 302 redirection
        PAGE=$(curl -i -b "$COOKIE_FILE" \
            -d "task=$FORM_TASK" "$URL") || return

        if match '<div class="error">' "$PAGE"; then
            ERR=$(echo "$PAGE" | parse_tag 'class="error">' div)

            # You have reached the limit of 3 files per hour for free users. Get premium for unlimited downloads.
            if match 'reached the limit' "$ERR"; then
                echo 600
                return $ERR_LINK_TEMP_UNAVAILABLE
            fi

            log_error "Remote error: $ERR"
            return $ERR_FATAL
        fi

        FILE_URL=$(grep_http_header_location <<< "$PAGE") || return
    fi

    echo "$FILE_URL"
    test -z "$FILE_NAME" || echo "$FILE_NAME"
}

# Probe a download URL. Use official API: http://www.filepup.net/api/docs.php
# $1: cookie file (unused here)
# $2: filepup.net url
# $3: requested capability list
# stdout: 1 capability per line
filepup_net_probe() {
    local -r URL=$(replace '/info/' '/files/' <<<"$2")
    local -r REQ_IN=$3
    local ID PAGE REQ_OUT

    # Plowshare API key
    local -r KEY='zO5098TJf39eF8HjjvZSqH9xSf00G5K'

    # Extract File ID
    ID=$(parse . '/files/\([^./]\+\)' <<< "$URL") || return
    log_debug "File ID: '$ID'"

    PAGE=$(curl --data "api_key=$KEY" --data "file_id=$ID" \
        'http://www.filepup.net/api/info.php') || return

    if match 'invalid api key' "$PAGE"; then
        log_error 'Wrong API key. API updated or key banned?'
        return $ERR_FATAL
    elif match 'file does not exist' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$PAGE" | parse '\[file_name\]' '=>[[:space:]]*\(.*\)' && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        echo "$PAGE" | parse '\[file_size\]' '=>[[:space:]]*\([[:digit:]]\+\)' && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        echo "$ID" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}
