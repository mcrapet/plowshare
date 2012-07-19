#!/bin/bash
#
# badongo.com module
# Copyright (c) 2010-2012 Plowshare team
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

MODULE_BADONGO_REGEXP_URL="http://\(www\.\)\?badongo\.com/"

MODULE_BADONGO_DOWNLOAD_OPTIONS=""
MODULE_BADONGO_DOWNLOAD_RESUME=no
MODULE_BADONGO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_BADONGO_UPLOAD_OPTIONS="
DESCRIPTION,d,description,S=DESCRIPTION,Set file description"
MODULE_BADONGO_UPLOAD_REMOTE_SUPPORT=no

MODULE_BADONGO_DELETE_OPTIONS=""

# Decode 'escaped' javascript code
# $1: HTML data
# $2: nth element to grep (index start at 1)
unescape_javascript() {
    local CODE=$(echo "$1" | grep '^eval((' | nth_line $2)
    (echo 'decodeURIComponent = function(x) { print(x); return x; }' && \
        echo 'var Event = { observe: function(a,b,c) {} };' && \
        echo 'var window = { beginDownload: function(isClick) {}, setTimeout: function(code,delay) {} };' && \
        echo "$CODE") | javascript
}

# Output a file URL to download from Badongo
# $1: cookie file
# $2: badongo url
# stdout: real file download link
badongo_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(echo "$2" | replace '/audio/' '/file/')
    local -r BASE_URL='http://www.badongo.com'
    local -r API_URL="$BASE_URL/ajax/prototype/ajax_api_filetemplate.php"

    local PAGE JSCODE ACTION MTIME CAPTCHA_URL
    local CAP_ID CAP_SECRET WAIT_PAGE LINK_PART2 LINK_PART1 LINK_FINAL FILE_URL

    PAGE=$(curl "$URL") || return

    if match '"recycleMessage">' "$PAGE"; then
        log_debug "file in recycle bin"
        return $ERR_LINK_DEAD
    fi

    # <div id="fileError">
    if match 'Not Found</\|"fileError">' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    detect_javascript || return

    JSCODE=$(curl -F 'rs=refreshImage' -F 'rst=' -F "rsrnd=$MTIME" \
        "$URL" | break_html_lines_alt) || return

    # Somebody from your IP address has not been obeying our rules
    if match 'Error - Denied</title>' "$JSCODE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    ACTION=$(echo "$JSCODE" | parse 'form' 'action=\\"\([^\\]*\)\\"') || return

    test "$CHECK_LINK" && return 0

    # Javascript: "now = new Date(); print(now.getTime());"
    MTIME="$(date +%s)000"

    # 200x60 jpeg file. Cookie file is not required (for curl)
    CAPTCHA_URL=$(echo "$JSCODE" | parse '<img' 'src=\\"\([^\\]*\)\\"')

    local WI WORD ID
    WI=$(captcha_process "$BASE_URL$CAPTCHA_URL" letters 4) || return
    { read WORD; read ID; } <<<"$WI"

    if [ "${#WORD}" -lt 4 ]; then
        captcha_nack $ID
        log_debug "captcha length invalid"
        return $ERR_CAPTCHA
    elif [ "${#WORD}" -gt 4 ]; then
        WORD="${WORD:0:4}"
    fi

    log_debug "decoded captcha: $WORD"

    CAP_ID=$(echo "$JSCODE" | parse_form_input_by_name 'cap_id')
    CAP_SECRET=$(echo "$JSCODE" | parse_form_input_by_name 'cap_secret')

    WAIT_PAGE=$(curl -c "$COOKIE_FILE" \
        -d "user_code=$WORD"          \
        -d "cap_id=$CAP_ID"           \
        -d "cap_secret=$CAP_SECRET"   \
        "$ACTION") || return

    if ! match 'id="link_container"' "$WAIT_PAGE"; then
        captcha_nack $ID
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug "correct captcha"

    JSCODE=$(unescape_javascript "$WAIT_PAGE" 6)

    # Look for doDownload function (now obfuscated)
    LINK_PART2=$(echo "$JSCODE" | parse_last 'location\.href' '+ "\([^"]*\)') || return

    JSCODE=$(unescape_javascript "$WAIT_PAGE" 2)

    # Look for window.[0-9A-F]{25} variable (timer)
    WAIT_TIME=$(echo "$JSCODE" | parse 'window\.' '[[:space:]]=[[:space:]]\([[:digit:]]\+\)')

    GLF_Z=$(echo "$JSCODE" | parse_last 'window\.getFileLinkInitOpt' "z = '\([^']*\)") || return
    GLF_H=$(echo "$JSCODE" | parse_last 'window\.getFileLinkInitOpt' "'h':'\([^']*\)") || return
    FILEID="${ACTION##*/}"
    FILETYPE='file'

    # Start remote timer
    JSON=$(curl -b "$COOKIE_FILE" --referer "$ACTION" \
            -d "id=$FILEID" -d "type=$FILETYPE" -d 'ext=' -d 'f=download%3Ainit' \
            -d "z=$GLF_Z" -d "h=$GLF_H" "$API_URL") || return
    JSCODE=$(unescape_javascript "$JSON" 1)

    # Parse received window['getFileLinkInitOpt'] object
    # Get new values of GLF_Z and GLF_H
    GLF_Z=$(echo "$JSCODE" | parse "'z'" "[[:space:]]'\([^']*\)") || return
    GLF_H=$(echo "$JSCODE" | parse "'h'" "[[:space:]]'\([^']*\)") || return
    GLF_T=$(echo "$JSCODE" | parse "'t'" "[[:space:]]'\([^']*\)") || return

    # Usual wait time is 60 seconds
    wait $((WAIT_TIME)) || return

    # Notify remote timer
    JSON=$(curl -b "$COOKIE_FILE" --referer "$ACTION" \
            -d "id=$FILEID" -d "type=$FILETYPE" -d 'ext=' -d 'f=download%3Acheck' \
            -d "z=$GLF_Z" -d "h=$GLF_H" -d "t=$GLF_T" "$API_URL") || return
    JSCODE=$(unescape_javascript "$JSON" 1)

    # Parse again received window['getFileLinkInitOpt'] object
    # Get new values of GLF_Z, GLF_H and GLF_T (and escape '!' character)
    GLF_Z=$(echo "$JSCODE" | parse "'z'" "[[:space:]]'\([^']*\)" | replace '!' '%21') || return
    GLF_H=$(echo "$JSCODE" | parse "'h'" "[[:space:]]'\([^']*\)" | replace '!' '%21') || return
    GLF_T=$(echo "$JSCODE" | parse "'t'" "[[:space:]]'\([^']*\)" | replace '!' '%21') || return

    JSCODE=$(curl --get -b '_gflCur=0' -b "$COOKIE_FILE" \
        -d 'rs=getFileLink' -d 'rst=' -d "rsrnd=$MTIME" \
        -d "rsargs[]=0&rsargs[]=yellow&rsargs[]=${GLF_Z}&rsargs[]=${GLF_H}&rsargs[]=${GLF_T}&rsargs[]=${FILETYPE}&rsargs[]=${FILEID}&rsargs[]=" \
        --referer "$ACTION" "$ACTION" | break_html_lines) || return

    LINK_PART1=$(echo "$JSCODE" | parse_last 'javascript' "\\\\'\(http[^\\]*\)") || return

    # Example: http://www.badongo.com/fd/0294088241036178/CCI9368696599696972/0/I!18b47cc7!9ccbab6f6695639867936a6d9969?zenc=
    FILE_URL="${LINK_PART1}${LINK_PART2}?zenc="

    PAGE=$(curl -b '_gflCur=0' -b "$COOKIE_FILE" --referer "$ACTION" \
        "$FILE_URL") || return
    JSCODE=$(unescape_javascript "$PAGE" 5)

    # Look for new location.href
    LINK_FINAL=$(echo "$JSCODE" | parse_last 'location\.href' "= '\([^']*\)") || return

    # Get HTTP headers
    FILE_URL=$(curl -i -b "$COOKIE_FILE" --referer "$FILE_URL" \
        "${BASE_URL}${LINK_FINAL}") || return

    echo "$FILE_URL" | grep_http_header_location || return
}

# Upload a file to Badongo
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
#         delete link
badongo_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://upload.badongo.com'
    local PAGE SESS_ID DESCR

    PAGE=$(curl "$BASE_URL/single_front/?cou=en") || return

    # Parse session ID
    SESS_ID=$(echo "$PAGE" | parse 'PHPSESSID' ', "\([0-9a-f]\+\)");') || return

    test "$DESCRIPTION" && DESCR=$(echo "$DESCRIPTION" | uri_encode_strict)

    # Note: This request requires both POST and query parameters and curl does
    #       not support simultanous use of -F and -d so we get one long URL :-(
    PAGE=$(curl_with_log --user-agent 'Shockwave Flash' \
        -F "Filename=$DEST_FILE" \
        -F "Filedata=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        -F 'Upload=Submit Query' \
        "$BASE_URL/mpu_upload_single.php?UL_ID=undefined&UPLOAD_IDENTIFIER=undefined&page=upload_s&s=&cou=en&PHPSESSID=$SESS_ID&desc=$DESCR") || return

    [ -n "$PAGE" ] || return $ERR_FATAL

    # Retrieve links
    PAGE=$(curl_with_log -d 'page=upload_s_f' -d "PHPSESSID=$SESS_ID" \
        -d 'url=undefined' -d 'url_kill=undefined' -d 'affliate=' \
        "$BASE_URL/upload_complete.php")

    # Extract + output links
    echo "$PAGE" | parse 'http' '&url=\([^&]\+\)' | uri_decode || return
    echo "$PAGE" | parse 'http' '&url_kill=\([^&]\+\)' | uri_decode || return
}

# Delete a file from Badongo
# $1: cookie file
# $2: badongo (delete) link
badongo_delete() {
    local PAGE

    PAGE=$(curl -b 'badongoL=en' "$2") || return
    match '<h3>File delete</h3>' "$PAGE" || return $ERR_FATAL
}
