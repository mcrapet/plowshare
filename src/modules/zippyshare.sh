# Plowshare zippyshare.com module
# Copyright (c) 2012-2014 Plowshare team
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

MODULE_ZIPPYSHARE_REGEXP_URL='https\?://\([[:alnum:]]\+\.\)\?zippyshare\.com/'

MODULE_ZIPPYSHARE_DOWNLOAD_OPTIONS=""
MODULE_ZIPPYSHARE_DOWNLOAD_RESUME=no
MODULE_ZIPPYSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_ZIPPYSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_ZIPPYSHARE_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_ZIPPYSHARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_ZIPPYSHARE_LIST_OPTIONS=""
MODULE_ZIPPYSHARE_LIST_HAS_SUBFOLDERS=yes

MODULE_ZIPPYSHARE_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base url
zippyshare_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE NAME

    LOGIN_DATA='login=$USER&pass=$PASSWORD'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/services/login" -b 'ziplocale=en') || return

    if [ -n "$PAGE" ]; then
        log_debug "$FUNCNAME: non empty result. Site updated?"
    fi

    # If successful, 5 entries are added into cookie file:
    # JSESSIONID, zipname, ziphash, manager-state, ZIPWEB
    if NAME=$(parse_cookie 'zipname' < "$COOKIE_FILE"); then
        log_debug "Successfully logged in as member '$NAME'"
        return 0
    fi

    return $ERR_LOGIN_FAILED
}

# Output a zippyshare file download URL
# $1: cookie file (unused here)
# $2: zippyshare url
# stdout: real file download link
zippyshare_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local PAGE FILE_URL FILE_NAME PART_URL CONTENT JS FUNC N

    # JSESSIONID required
    PAGE=$(curl -c "$COOKIE_FILE" -b 'ziplocale=en' "$URL") || return

    # File does not exist on this server
    # File has expired and does not exist anymore on this server
    if match 'File does not exist\|File has expired\|HTTP Status 404' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    detect_javascript || return

    # <meta property="og:title" content="... "
    FILE_NAME=$(echo "$PAGE" | parse_attr '=.og:title.' content) || return
    test "$FILE_NAME" = 'Private file' && FILE_NAME=''

    if match 'var[[:space:]]*submitCaptcha' "$PAGE"; then
        local PART1 PART2
        local -r BASE_URL=$(basename_url "$URL")

        PART1=$(echo "$PAGE" | parse '/captcha' 'url:[[:space:]]*"\([^"]*\)') || return
        N=$(echo "$PAGE" | parse 'shortencode' "shortencode:[[:space:]]*'\([[:digit:]]*\)") || return
        PART2=$(echo "$PAGE" | parse '/d/' "=[[:space:]]*'\([^']*\)") || return

        # Recaptcha.create
        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LeIaL0SAAAAAMnofB1i7QAJta9G7uCipEPcp89r'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

        PAGE=$(curl -b "$COOKIE_FILE" --referer "$URL" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d "challenge=$CHALLENGE" \
            -d "response=$WORD" \
            -d "shortencode=$N" \
            "$BASE_URL$PART1") || return

        # Returns "true" or "false"
        if [ "$PAGE" != 'true' ]; then
            captcha_nack $ID
            log_debug 'reCaptcha error'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug 'correct captcha'

        echo "$BASE_URL$PART2"
        echo "${FILE_NAME% }"
        return 0
    fi

    # Detect type of content
    # <meta property="og:type" content="..." />
    PAGE=$(strip_html_comments <<< "$PAGE")
    CONTENT=$(parse_attr_quiet '=.og:type.' 'content' <<< "$PAGE")
    log_debug "Content Type: '$CONTENT'"

    case "$CONTENT" in
        'music.song')
            N=-8
            ;;
        'image')
            N=-1
            ;;
        '')
            N=-5
            ;;
        *)
            log_error "Unexpected content ('$CONTENT'), site updated?"
            return $ERR_FATAL
    esac

    JS=$(grep_script_by_order "$PAGE" $N) || return

    # Sanity check 1
    if match '<script[[:space:]][^>]\+></script>' "$JS"; then
        log_error "Unexpected javascript content (N=$N)"
        #JS=$(grep_script_by_order "$PAGE" $((N+1))) || return
        #log_error "+1 [$JS]"
        #JS=$(grep_script_by_order "$PAGE" $((N-1))) || return
        #log_error "-1 [$JS]"
        return $ERR_FATAL
    fi

    JS=$(delete_first_line <<< "$JS" | delete_last_line)

    # Sanity check 2
    if [ -z "$JS" ]; then
        log_error "Unexpected error (N=$N)"
        log_debug "js: '$(grep_script_by_order "$PAGE" $N)'"
        return $ERR_FATAL
    fi

    # Find the function to call
    # var somefunction = function() {somffunction()};
    FUNC=$(parse_quiet 'var somefunction = ' '{\([^}]\+\)}' <<< "$PAGE")

    PART_URL=$(echo "var elts = new Array();
        var document = {
          getElementById: function(id) {
            if (! elts[id]) { elts[id] = {}; }
            return elts[id];
          }
        };
        $JS
        $FUNC;
        print(elts['dlbutton'].href);" | javascript) || return

    FILE_URL="$(basename_url "$URL")$PART_URL"

    echo "$FILE_URL"
    echo "${FILE_NAME% }"
}

# Upload a file to zippyshare.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: zippyshare.com download link
zippyshare_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://www.zippyshare.com'
    local PAGE SERVER FORM_HTML FORM_ACTION FORM_UID FILE_URL FORM_DATA_AUTH

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt 209715200 ]; then
        log_debug 'file is bigger than 200MB'
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$AUTH" ]; then
        zippyshare_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" ||Â return
    fi

    PAGE=$(curl -L -b "$COOKIE_FILE" -b 'ziplocale=en' "$BASE_URL") || return

    SERVER=$(echo "$PAGE" | parse 'var[[:space:]]*server' "'\([^']*\)';")
    log_debug "Upload server $SERVER"

    FORM_HTML=$(grep_form_by_id "$PAGE" 'upload_form') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'uploadId') || return

    if [ -n "$AUTH" ]; then
        local NAME HASH
        NAME=$(parse_cookie 'zipname' < "$COOKIE_FILE")
        HASH=$(parse_cookie 'ziphash' < "$COOKIE_FILE")
        FORM_DATA_AUTH="-F zipname=$NAME -F ziphash=$HASH"
    fi

    # Important: field order seems checked! zipname/ziphash go before Filedata!
    PAGE=$(curl_with_log -F "uploadId=$FORM_UID" \
        $FORM_DATA_AUTH \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        "$FORM_ACTION") || return

    # Take first occurrence
    FILE_URL=$(echo "$PAGE" | parse '="file_upload_remote"' '^\(.*\)$' 1) || return

    echo "$FILE_URL"
}

# List a zippyshare folder
# $1: zippyshare user link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
zippyshare_list() {
    local -r URL=$1
    local USER IDENT RET=0

    PAGE=$(curl -L "$URL") || return

    USER=$(echo "$PAGE" | parse 'var[[:space:]]*user[[:space:]]*=[[:space:]]*enc' \
        "('\([^']*\)" | uri_encode) || return
    IDENT=$(echo "$PAGE" | parse 'getTree' 'ident=\([^"]*\)') || return
    log_debug "User: '$USER'"
    log_debug "Ident: '$IDENT'"

    # FIXME:
    # - For audio files. Filename is "Download Now!"
    # - If IDENT=0 find default directory

    zippyshare_list_rec "$USER" "$IDENT" "${2:-0}" "$URL" || RET=$?
    return $RET
}

# static recursive function
# $1: recursive flag
# $2: web folder URL
zippyshare_list_rec() {
    local -r USER=$1
    local -r IDENT=$2
    local -r REC=$3
    local URL=$4
    local -r BASE_URL='http://zippyshare.com'
    local PAGE PAGE2 LINKS NAMES RET LINE

    RET=$ERR_LINK_DEAD

    PAGE=$(curl --get -d 'locale=en' \
        "$BASE_URL/$USER/$IDENT/dir.html") || return

    if match '/v/' "$PAGE"; then
        PAGE2=$(echo "$PAGE" | parse_all '/v/' '^\(.*\)$')
        NAMES=$(echo "$PAGE2" | parse_all_tag a)
        LINKS=$(echo "$PAGE2" | parse_all_attr href)
        list_submit "$LINKS" "$NAMES" && RET=0

    # Directory is password protected. Please enter password.
    elif matchi 'directory is password protected' "$PAGE"; then
        log_error "Password protected directory: $BASE_URL/$USER/$IDENT/dir.html"
        # TODO: POST /rest/public/authenticate id=xxx&pass=yyy
    fi

    # FIXME: Process subtree and not whole tree.
    if [[ $REC -eq 1 ]]; then
        # Whatever IDENT the whole 'absolute' tree is returned
        JSON=$(curl --get -d "user=$USER" -d "ident=$IDENT" \
            "$BASE_URL/rest/public/getTree") || return
        LINKS=$(echo "$JSON" | parse_json 'ident' split) || return
        NAMES=$(echo "$JSON" | parse_json 'data' split) || return

        while read LINE; do
            test "$LINE" || continue
            URL="$BASE_URL/$USER/$LINE/dir.html"
            if [ "$LINE" != "$IDENT" ]; then
                log_debug "entering sub folder: $URL"
                zippyshare_list_rec "$USER" "$LINE" "$((REC+1))" "$URL" && RET=0
            fi
        done <<< "$LINKS"
    fi

    return $RET
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: zippyshare url
# $3: requested capability list
# stdout: 1 capability per line
zippyshare_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_NAME REQ_OUT

    PAGE=$(curl -L -b 'ziplocale=en' "$URL") || return

    # File does not exist on this server
    # File has expired and does not exist anymore on this server
    if match 'File does not exist\|File has expired\|HTTP Status 404' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        # <meta property="og:title" content="... "
        FILE_NAME=$(echo "$PAGE" | parse_attr '=.og:title.' content) && \
            echo "${FILE_NAME% }" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse '>Size:<' '">\([^<]*\)</font>') && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
