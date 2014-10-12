# filecore.co.nz module
# Copyright (c) 2014 Plowshare team
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

MODULE_FILECORE_REGEXP_URL='https\?://\(www\.\)\?\(fcore\.eu\|filecore\.co\.nz\)/'

MODULE_FILECORE_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_FILECORE_DOWNLOAD_RESUME=yes
MODULE_FILECORE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FILECORE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FILECORE_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: credentials string
# $2: cookie file
# $3: base url
filecore_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT NAME ERR

    LOGIN_DATA='op=login&redirect=&login=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL") || return

    # Set-Cookie: login xfss
    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -n "$NAME" ]; then
        log_debug "Successfully logged in as $NAME member"
        return 0
    fi

    # Try to parse error
    ERR=$(parse_tag_quiet 'class="err"' 'font' <<< "$LOGIN_RESULT")
    [ -n "$ERR" ] || ERR=$(parse_tag_quiet "class='err'" 'div' <<< "$LOGIN_RESULT")
    [ -n "$ERR" ] && log_error "Unexpected remote error: $ERR"

    return $ERR_LOGIN_FAILED
}

# Output a filecore file download URL
# $1: cookie file (unused here)
# $2: filecore url
# stdout: real file download link
filecore_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://filecore.co.nz'
    local PAGE POST_URL PUBKEY RESP CAPTCHA_DATA ERR
    local FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_METHOD_F FORM_METHOD_P FORM_DD FORM_DS

    if [ -n "$AUTH_FREE" ]; then
        filecore_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

        # Distinguish acount type (free or premium)
        #PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=my_account") || return
    fi

    # Set-Cookie: fid
    PAGE=$(curl -v --location --include -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return

    POST_URL=$(grep_http_header_location_quiet <<< "$PAGE" | last_line)
    if [ -z "$POST_URL" ]; then
        log_error "Unexpected content. Site updated?"
       return $ERR_FATAL
    fi
    log_debug "post url: '$POST_URL'"

    # The page you are looking for cannot be found.
    if match '<title>www.filecore.co.nz | 404 - Page Cannot Be Found</title>' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif ! match '<title>Download Page</title>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")
    FORM_METHOD_P=$(parse_form_input_by_name_quiet 'method_premium' <<< "$FORM_HTML")
    FORM_DD=$(parse_form_input_by_name 'down_direct' <<< "$FORM_HTML") || return
    FORM_DS=$(parse_form_input_by_name 'down_script' <<< "$FORM_HTML") || return

    # Check for Captcha
    if match 'api\.solvemedia\.com' "$FORM_HTML"; then
        log_debug 'Solve Media CAPTCHA found'

        PUBKEY='VaxxhFnyEHmhP6jbvTSc0U0t0b8kzzUI'
        RESP=$(solvemedia_captcha_process $PUBKEY) || return
        { read CHALL; read ID; } <<< "$RESP"

        CAPTCHA_DATA="-d adcopy_challenge=$CHALL -d adcopy_response=none"

        # If we reach here, it means that captcha is good
        log_debug 'Correct captcha'
        captcha_ack "$ID"
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -d "op=$FORM_OP" -d "id=$FORM_ID" -d "rand=$FORM_RAND" \
        -d 'referer=' -d "method_free=$FORM_METHOD_F" \
        -d "method_premium=$FORM_METHOD_P" $CAPTCHA_DATA \
        -d "down_direct=$FORM_DD" -d "down_script=$FORM_DS" \
        "$POST_URL") || return

    # Get error message, if any
    ERR=$(parse_tag_quiet '<div class="err"' 'div' <<< "$PAGE")
    if [ -n "$ERR" ]; then
        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    parse_attr '/download_linker\.' href <<< "$PAGE" || return
    parse_tag 'colspan=.2.><b>' b <<< "$PAGE" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: filecore url
# $3: requested capability list
# stdout: 1 capability per line
filecore_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE
    local -r BASE_URL='http://filecore.co.nz/?op=checkfiles'

    PAGE=$(curl -b 'lang=english' --referer "$BASE_URL" \
        -d 'op=checkfiles' -d 'process=check' \
        --data-urlencode "list=$URL" "$BASE_URL") || return

    if match '">Filename don'\''t match!</' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif ! match '">Found</' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '>Found</' '<td>\([^<]*\)' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
