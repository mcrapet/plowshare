# Plowshare shareonline.biz module
# Copyright (c) 2012-2013 Plowshare team
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

MODULE_SHAREONLINE_BIZ_REGEXP_URL='http://\(\www\.\)\?\(share\-online\.biz\|egoshare\.com\)/\(download\.php?id\=\|dl/\)\(\w\)'

MODULE_SHAREONLINE_BIZ_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_SHAREONLINE_BIZ_DOWNLOAD_RESUME=no
MODULE_SHAREONLINE_BIZ_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_SHAREONLINE_BIZ_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_SHAREONLINE_BIZ_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)"
MODULE_SHAREONLINE_BIZ_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success
shareonline_biz_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=${3/#http/https}
    local LOGIN_DATA PAGE ID TYPE ERR

    LOGIN_DATA='user=$USER&pass=$PASSWORD'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/user/login" -b "$COOKIE_FILE") || return

    # Successful login just redirects and returns an empty page
    if [ -n "$PAGE" ]; then
        ERR=$(parse_tag 'h2' <<< "$PAGE") || return
        log_debug "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    # Determine account type
    PAGE=$(curl -b "$COOKIE_FILE" -b 'page_language=english' \
        "$BASE_URL/user/profile") || return
    ID=$(parse_tag 'Logged in as' 'a' <<<  "$PAGE") || return
    TYPE=$(parse 'Your Account-Type' '^\([[:alpha:]-]\+\)' 3 <<<  "$PAGE") || return

    case "$TYPE" in
        'Sammler')
            TYPE='free'
            ;;
        'Premium'|'Penalty-Premium'|'VIP-Special')
            [ "$TYPE" = 'Penalty-Premium' ] && log_error 'Account is in penalty state!'
            TYPE='premium'
            ;;
        *)
            log_error 'Could not determine account type. Site updated?'
            return $ERR_FATAL
            ;;
    esac

    log_debug "Successfully logged in as $TYPE member '$ID'"
    echo "$TYPE"
}

# Switch language to english
# $1: cookie file
# $2: base URL
shareonline_biz_switch_lang() {
    # Note: Language is associated with session, faking the cookie is not enough
    curl -c "$1" -o /dev/null "$2/lang/set/english" || return
}

# Output an shareonline.biz file download URL
# $1: cookie file
# $2: shareonline.biz url
# stdout: real file download link
shareonline_biz_download() {
    local -r BASE_URL='http://www.share-online.biz'
    local URL FILE_ID PAGE ACCOUNT REDIR BASE64LINK
    local API_FILE_ID FILE_STATUS FILE_NAME SIZE FILE_URL
    local CAP_ID URL_ID WAIT

    # Extract file ID from all possible URL formats
    #  http://www.share-online.biz/download.php?id=xyz
    #  http://share-online.biz/download.php?id=xyz
    FILE_ID=$(parse_quiet . 'id=\([[:alnum:]]\+\)$' <<< "$2")

    #  http://www.share-online.biz/dl/xyz
    #  http://share-online.biz/dl/xyz
    if [ -z "$FILE_ID" ]; then
        FILE_ID=$(parse_quiet . '/dl/\([[:alnum:]]\+\)$' <<< "$2")
    fi

    if [ -z "$FILE_ID" ]; then
        log_error 'Could not get file ID. Site updated?'
        return $ERR_FATAL
    fi

    FILE_ID=$(uppercase "$FILE_ID")
    log_debug "File ID: '$FILE_ID'"
    URL="$BASE_URL/dl/$FILE_ID/"

    # Get data from shareonline API
    # Note: API requires ID to be uppercase
    PAGE=$(curl -d "links=$FILE_ID" "${BASE_URL/www/api}/linkcheck.php") || return
    log_debug "API response: $PAGE"

    IFS=";" read API_FILE_ID FILE_STATUS FILE_NAME SIZE <<< "$PAGE"

    log_debug "File ID: $API_FILE_ID"
    log_debug "File status: $FILE_STATUS"
    log_debug "Filename: $FILE_NAME"
    log_debug "File size: $SIZE"

    # The requested file isn't available anymore!
    [ "$FILE_STATUS" = 'OK' ] || return $ERR_LINK_DEAD

    if [ -n "$AUTH" ]; then
        shareonline_biz_switch_lang "$COOKIE_FILE" "$BASE_URL" || return
        ACCOUNT=$(shareonline_biz_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Handle premium download
    if [ "$ACCOUNT" = 'premium' ]; then
        # 'Direct download' may be active in which case the site redirects
        # to the final URL immediately. Also, an extra cookie ('a') is
        # required for premium downloads in any case.
        PAGE=$(curl --include -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return
        FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

        # No 'direct download', so get URL from the page
        if [ -z "$FILE_URL" ]; then
            if ! check_exec 'base64'; then
                log_error "'base64' is required but was not found in path."  \
                    "Alternatively you may activate the 'Direct Download'"   \
                    "feature in your profile (use your browser to login and" \
                    "open 'https://www.share-online.biz/user/config')."
                return $ERR_SYSTEM
            fi

            BASE64LINK=$(parse 'var[[:space:]]dl=' \
                '[[:space:]]dl="\([^"]\+\)"' <<< "$PAGE") || return
            FILE_URL=$(base64 --decode <<< "$BASE64LINK") || return
        fi

        MODULE_SHAREONLINE_BIZ_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

        # Check for problems
        PAGE=$(curl --head -b "$COOKIE_FILE" "$FILE_URL") || return
        REDIR=$(grep_http_header_location_quiet <<< "$PAGE")

        if [ -n "$REDIR" ]; then
            local ERR=$(parse_quiet . 'failure/\([^/]\+\)' <<< "$REDIR")

            case $ERR in
                ip)
                    log_error 'Account used from multiple IP addresses'
                    ;;
                *)
                    # Note: This also matches when "$ERR" is empty.
                    log_error "Unexpected server response (REDIR = '$REDIR'). Site updated?"
                    ;;
            esac

            return $ERR_FATAL
        fi

        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0
    fi

    if ! check_exec 'base64'; then
        log_error "'base64' is required but was not found in path."
        return $ERR_SYSTEM
    fi

    URL="${URL}free/"

    # Load second page
    PAGE=$(curl --include -d 'dl_free=1' -d 'choice=free' "$URL" ) || return

    # Handle errors/redirects
    REDIR=$(grep_http_header_location_quiet <<< "$PAGE")
    if [ -n "$REDIR" ]; then
        local ERR=$(parse_quiet . 'failure/\([^/]\+\)' <<< "$REDIR")

        case $ERR in
            ipfree)
                log_error 'No parallel download allowed.'
                ;;
            full)
                log_error 'No free download possible at the moment.'
                ;;
            session|bandwidth|overload|cookie|expired|invalid|precheck|proxy|threads|server|chunks)
                log_error 'Server issues.'
                ;;
            freelimit)
                return $ERR_LINK_NEED_PERMISSIONS
                ;;
            size)
                return $ERR_SIZE_LIMIT_EXCEEDED
                ;;
            *)
                # Note: This also matches when "$ERR" is empty.
                log_error "Unexpected server response (REDIR = '$REDIR'). Site updated?"
                return $ERR_FATAL
                ;;
        esac

        echo 120 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Second Page is reCaptcha page if there was no error
    if ! match 'var captcha = false' "$PAGE"; then
        log_error 'No captcha requested? Please report this issue'
        return $ERR_FATAL
    fi

    CAP_ID=$(parse 'var[[:space:]]\+dl=' \
        '[[:space:]]dl="\([^"]*\)' <<< "$PAGE") || return
    CAP_ID=$(base64 --decode <<< "$CAP_ID") || return
    URL_ID=$(parse '///' '///\([[:digit:]]\+\)' <<< "$PAGE") || return
    log_debug "Captcha: '$CAP_ID'"
    log_debug "URL ID: $URL_ID"

    # Solve recaptcha
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6LdatrsSAAAAAHZrB70txiV5p-8Iv8BtVxlTtjKX'
    WCI=$(recaptcha_process $PUBKEY)
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    # Wait before send recaptcha data (and then again before actual download)
    # 'var wait=30; [...] <current time> + wait/2'
    WAIT=$(parse 'var wait' 'wait=\([[:digit:]]\+\)' <<< "$PAGE") || return
    wait $(( ($WAIT / 2) + 1 )) || return

    BASE64LINK=$(curl -b "$COOKIE_FILE" -d 'dl_free=1' \
        -d "captcha=${CAP_ID:5}" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        "${URL}captcha/$URL_ID") || return

    case "$BASE64LINK" in
        '')
            log_error 'File URL not found. Site updated?'
            return $ERR_FATAL
            ;;
        '0')
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA
            ;;
    esac

    captcha_ack $ID
    log_debug 'Correct captcha'

    wait $(( $WAIT + 1 )) || return

    FILE_URL=$(base64 --decode <<< "$BASE64LINK") || return
    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to Share-Online.biz
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: shareonline download link
shareonline_biz_upload() {
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r REQUEST_URL='http://www.share-online.biz/upv3_session.php'
    local DATA USER PASSWORD ERR UP_URL SESSION_ID SIZE SIZE_SRV LINK MD5

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    # We use the public upload API (http://www.share-online.biz/uploadapi/)

    split_auth "$AUTH" USER PASSWORD || return

    # Create upload session
    DATA=$(curl -F "username=$USER" -F "password=$PASSWORD" "$REQUEST_URL") || return

    if match '<title>502 Bad Gateway</title>' "$DATA"; then
        log_error 'Remote server error, maybe due to overload.'
        echo 120 # arbitrary time
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    ERR=$(echo "$DATA" | parse_quiet '^\*\*\* EXCEPTION \(.\+\) -')
    if [ -n "$ERR" ]; then
        if [ "$ERR" = 'username or password invalid' ]; then
            return $ERR_LOGIN_FAILED
        fi

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    # EN29W3AMYGX0;dlw159-2.share-online.biz/upload
    IFS=';' read SESSION_ID UP_URL <<< "$DATA"

    match_remote_url $UP_URL || UP_URL="http://$UP_URL"
    SIZE=$(get_filesize "$FILE") || return

    DATA=$(curl -F "username=$USER" -F "password=$PASSWORD" \
        -F "upload_session=$SESSION_ID" -F 'chunk_no=1' -F 'chunk_number=1' \
        -F "filesize=$SIZE" -F "fn=@$FILE;filename=$DEST_FILE" -F 'finalize=1' \
        "$UP_URL") || return

    ERR=$(echo "$DATA" | parse_quiet '^\*\*\* EXCEPTION \(.\+\) -')

    if [ -n "$ERR" ]; then
        if [ "$ERR" = 'session creation/reuse failed -' ]; then
            log_error 'Server reports invalid session'
            return $ERR_FATAL
        fi

        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    # http://www.share-online.biz/dl/8XDBW3AM57;128;656957fb0a59502fc47c7c01a814d21f
    IFS=";" read LINK SIZE_SRV MD5 <<< "$DATA"

    log_debug "File size on server: $SIZE_SRV"
    log_debug "MD5 hash: $MD5"

    if [ $SIZE -ne $SIZE_SRV ]; then
        log_error "Server reports wrong filesize: $SIZE_SRV (local: $SIZE)"
    fi

    echo "$LINK"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: shareonline_biz url
# $3: requested capability list
# stdout: 1 capability per line
shareonline_biz_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE TEMP DLID REQ_OUT

    PAGE=$(curl -L "$URL") || return
    DLID=$(echo "$PAGE" | parse_quiet '[[:space:]/]dl/' 'dl/\([[:alnum:]]\+\)[</]')

    test "$DLID" || return $ERR_LINK_DEAD

    # Official API Documentation
    # http://www.share-online.biz/linkcheckapi/
    TEMP=$(curl -d "links=$DLID" \
        'http://api.share-online.biz/linkcheck.php?md5=1') || return

    log_debug "API response: '$TEMP'"

    local ID FILE_STATUS FILE_NAME SIZE HASH
    IFS=";" read ID FILE_STATUS FILE_NAME SIZE HASH <<< "$TEMP"

    # The requested file isn't available anymore!
    if [ "$FILE_STATUS" != 'OK' ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        test "$FILE_NAME" && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *h* ]]; then
        test "$HASH" && echo "$HASH" && REQ_OUT="${REQ_OUT}h"
    fi

    if [[ $REQ_IN = *s* ]]; then
        test "$SIZE" && echo "$SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
