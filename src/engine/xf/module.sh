#!/bin/bash
#
# xfilesharing template module
# Copyright (c) 2013 Plowshare team
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

MODULE_XFILESHARING_REGEXP_URL="https\?://"

MODULE_XFILESHARING_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_XFILESHARING_DOWNLOAD_RESUME=yes
MODULE_XFILESHARING_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_XFILESHARING_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_XFILESHARING_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
HOSTING,,hosting,s=URL,Full base URL of xfileshare hosting
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
FOLDER,,folder,s=FOLDER,Folder to upload files into
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email
PREMIUM,,premium,,Make file inaccessible to non-premium users
PRIVATE_FILE,,private,,Do not make file visible in folder view"
MODULE_XFILESHARING_UPLOAD_REMOTE_SUPPORT=no

MODULE_XFILESHARING_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=()

MODULE_XFILESHARING_DELETE_OPTIONS=""
MODULE_XFILESHARING_PROBE_OPTIONS=""
MODULE_XFILESHARING_LIST_OPTIONS=""

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
xfilesharing_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT STATUS NAME

    log_debug 'Logging in...'

    LOGIN_DATA='op=login&login=$USER&password=$PASSWORD&redirect='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA$BASE_URL/?op=my_account" \
        "$BASE_URL" -L -b 'lang=english') || return

    # If successful, two entries are added into cookie file: login and xfss
    STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
    if [ -z "$STATUS" ]; then
        return $ERR_LOGIN_FAILED
    fi

    NAME=$(parse_cookie 'login' < "$COOKIE_FILE")
    log_debug "Successfully logged in as $NAME member"
}

# Check if account has enough space to upload file
# $1: upload file size
# $2: cookie file (logged into account)
# $3: base URL
xfilesharing_check_freespace() {
    local -r FILE_SIZE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local PAGE SPACE_USED SPACE_LIMIT

    PAGE=$(curl -b 'lang=english' -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL") || return

    # XXX Kb of XXX GB
    SPACE_USED=$(echo "$PAGE" | parse 'Used space' \
        ' \([0-9.]\+[[:space:]]*[KMGBb]\+\) of ') || return
    SPACE_USED=$(translate_size "$(uppercase "$SPACE_USED")")

    SPACE_LIMIT=$(echo "$PAGE" | parse 'Used space' \
        'of \([0-9.]\+[[:space:]]*[KMGBb]\+\)') || return
    SPACE_LIMIT=$(translate_size "$(uppercase "$SPACE_LIMIT")")

    log_debug "Space: $SPACE_USED / $SPACE_LIMIT"

    # Check space limit
    if (( ( "$SPACE_LIMIT" - "$SPACE_USED" ) < "$FILE_SIZE" )); then
        log_error 'Not enough space in account folder.'
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi
}

# Check if specified folder name is valid.
# When multiple folders wear the same name, first one is taken.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base URL
# stdout: folder ID
xfilesharing_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local PAGE FORM FOLDERS FOL FOL_ID

    # Special treatment for root folder (always uses ID "0")
    if [ "$NAME" = '/' ]; then
        echo 0
        return 0
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL") || return
    FORM=$(grep_form_by_name "$PAGE" 'F1') || return

    # <option value="ID">&nbsp;NAME</option>
    # Note: - Site uses "&nbsp;" to indent sub folders
    #       - First entry is label "Move files to folder"
    #       - Second entry is root folder "/"
    FOLDERS=$(echo "$FORM" | parse_all_tag option | delete_first_line 2 |
        replace '&nbsp;' '') || return

    if ! match "^$NAME$" "$FOLDERS"; then
        log_debug 'Creating folder.'
        PAGE=$(curl -b "$COOKIE_FILE" -L \
            -d 'op=my_files' \
            -d 'fld_id=0' \
            -d "create_new_folder=$NAME" \
            "$BASE_URL") || return

        FORM=$(grep_form_by_name "$PAGE" 'F1') || return

        FOLDERS=$(echo "$FORM" | parse_all_tag option | delete_first_line 2 |
            replace '&nbsp;' '') || return
        if [ -z "$FOLDERS" ]; then
            log_error 'No folder found. Site updated?'
            return $ERR_FATAL
        fi

        if ! match "^$NAME$" "$FOLDERS"; then
            log_error "Could not create folder."
            return $ERR_FATAL
        fi
    fi

    FOL_ID=$(echo "$FORM" | parse_attr "<option.*$NAME</option>" 'value')
    if [ -z "$FOL_ID" ]; then
        log_error "Could not get folder ID."
        return $ERR_FATAL
    fi

    echo "$FOL_ID"
}

# Unpack packed(obfuscated) js code
# $1: js script to unpack
# stdout: unpacked js script
xfilesharing_unpack_js() {
    local PACKED_SCRIPT=$1
    local UNPACK_SCRIPT

    UNPACK_SCRIPT="
    //////////////////////////////////////////
    //  Un pack the code from the /packer/  //
    //  By matthew@matthewfl.com            //
    //  http://matthewfl.com/unPacker.html  //
    //////////////////////////////////////////
    function unPack(code) {
        code = unescape(code);
        var env = {
            eval: function(c) {
                code = c;
            },
            window: {},
            document: {}
        };
        eval(\"with(env) {\" + code + \"}\");
        code = (code + \"\").replace(/;/g, \";\\n\").replace(/{/g, \"\\n{\\n\").replace(/}/g, \"\\n}\\n\").replace(/\\n;\\n/g, \";\\n\").replace(/\\n\\n/g, \"\\n\");
        return code;
    }"

    # urlencoding script with all quotes and backslashes to push it into unpack function as string
    PACKED_SCRIPT=$(echo "$PACKED_SCRIPT" | uri_encode_strict | replace '\' '%5C')
    echo "$PACKED_SCRIPT_CLEAN $UNPACK_SCRIPT print(unPack('$PACKED_SCRIPT'));" | javascript || return
}

# Search and handle streaming player scripts
# $1: page
# $2: url of page with player (required by some rtmp)
# $2: filename (if known)
# stdout: real file download link
xfilesharing_parse_streaming () {
    local PAGE=$1
    local -r URL=$2
    local -r FILE_NAME=$3
    local JS_PLAYER_FOUND=0
    local RE_PLAYER="jwplayer([\"']flvplayer[\"']).setup\|new SWFObject.*player\|DivXBrowserPlugin\|StrobeMediaPlayback.swf"

    if match '<script[^>]*>eval(function(p,a,c,k,e,d)' "$PAGE"; then
        log_debug 'Found some packed script (type 1)...'

        detect_javascript || return

        SCRIPTS=$(echo "$PAGE" | parse_all "<script[^>]*>eval(function(p,a,c,k,e,d)" "<script[^>]*>\(eval.*\)$")

        while read -r JS; do
            JS=$(xfilesharing_unpack_js "$JS")

            if match "$RE_PLAYER" "$JS"; then
                log_debug "Found some player code in packed script (type 1)."
                JS_PLAYER_FOUND=1
                PAGE="$JS"
                break
            fi

            [ -z "$FILE_URL" ] && log_debug 'Checking another script...'
        done <<< "$SCRIPTS"

        [ -z JS_PLAYER_FOUND ] && log_debug 'Nothing found in packed script (type 1).'
    fi

    # www.zinwa.com special
    if match 'function decodejs(instr,icount)' "$PAGE"; then
        log_debug 'Found some packed script (type 2)...'

        detect_javascript || return

        SCRIPT_N=1
        SCRIPTS=$(echo "$PAGE" | parse_all '<script' '^\(.*\)$' 1)

        while read JS; do
            if match 'function decodejs(instr,icount)' "$JS"; then
                break
            fi
            (( SCRIPT_N++ ))
        done <<< "$SCRIPTS"

        JS=$(grep_script_by_order "$PAGE" $SCRIPT_N | delete_first_line | delete_last_line | replace $'\r' '' | replace $'\n' '')
        JS=$(xfilesharing_unpack_js "$JS")

        if matchi "$RE_PLAYER" "$JS"; then
            log_debug "Found some player code in packed script (type 2)."
            PAGE="$JS"
        else
            log_debug 'Nothing found in packed script (type 2).'
        fi
    fi

    if matchi "jwplayer([\"']flvplayer[\"']).setup\|new SWFObject.*player" "$PAGE"; then
        if match 'streamer.*rtmp' "$PAGE"; then
            RTMP_BASE=$(echo "$PAGE" | parse 'streamer.*rtmp' "[\"']\?streamer[\"']\?[[:space:]]*[,\:][[:space:]]*[\"']\?\(rtmp[^'^\"^)]\+\)")
            RTMP_PLAYPATH=$(echo "$PAGE" | parse 'file' "[\"']\?file[\"']\?[[:space:]]*[,\:][[:space:]]*[\"']\?\([^'^\"^)]\+\)")

            FILE_URL="$RTMP_BASE playpath=$RTMP_PLAYPATH"

        # videopremium.tv special
        elif match 'file":"rtmp' "$PAGE"; then
            RTMP_SRC=$(echo "$PAGE" | parse 'file":"rtmp' '"file":"\(rtmp[^"]\+\)')
            RTMP_SWF=$(echo "$PAGE" | parse 'new swfobject.embedSWF("' 'new swfobject.embedSWF("\([^"]\+\)')

            RTMP_PLAYPATH=$(echo "$RTMP_SRC" | parse . '^.*/\([^/]*\)$')
            RTMP_BASE=$(echo "$RTMP_SRC" | parse . '^\(.*\)/[^/]*$')

            FILE_URL="$RTMP_BASE pageUrl=$URL playpath=$RTMP_PLAYPATH swfUrl=$RTMP_SWF"
        else
            FILE_URL=$(echo "$PAGE" | parse 'file.*http' "[\"']\?file[\"']\?[[:space:]]*[,\:][[:space:]]*[\"']\?\(http[^'^\"^)]\+\)")
        fi

    # www.donevideo.com special
    elif match '<object[^>]*DivXBrowserPlugin' "$PAGE"; then
        FILE_URL=$(echo "$PAGE" | parse '<object[^>]*DivXBrowserPlugin' 'id="np_vid"[^>]*src="\([^"]\+\)')

    # www.lovevideo.tv special
    elif match 'StrobeMediaPlayback.swf' "$PAGE"; then
        # rtmp://50.7.69.178/vod000027/ey5ozfhq448b.flv?e=1378429062&st=f-o_ItdghTPRSnILtjgnng
        # "rtmp://50.7.69.178/vod000027 pageUrl=http://www.lovevideo.tv/4fnfwqtu1typ playpath=ey5ozfhq448b.flv?e=1378464032&st=Bg1WAlpO3wr9HRkteAy4ng"
        RTMP_SRC=$(echo "$PAGE" | parse 'StrobeMediaPlayback.swf' "value='src=\(rtmp[^&]\+\)" | uri_decode | replace '%3F' '?')
        RTMP_PLAYPATH=$(echo "$RTMP_SRC" | parse . '^.*/\([^/]*\)$')
        RTMP_BASE=$(echo "$RTMP_SRC" | parse . '^\(.*\)/[^/]*$')

        # Need to add some exception for rtmp links
        FILE_URL="$RTMP_BASE pageUrl=$URL playpath=$RTMP_PLAYPATH"
    fi

    if [ -n "$FILE_URL" ]; then
        echo "$FILE_URL"
        [ -n "$FILE_NAME" ] && echo "$FILE_NAME"
        return 0
    fi

    return 1
}

# Check and parse contdown timer
# $1: page
# stdout: time to wait
xfilesharing_handle_countdown () {
    local -r PAGE=$1
    local WAIT_TIME PAGE_UNBREAK

    if match '"countdown_str"' "$PAGE"; then
        WAIT_TIME=$(echo "$PAGE" | parse_quiet 'countdown_str' \
            'countdown_str.*<span[^>]*id="[[:alnum:]]\{6\}">[[:space:]]*\([0-9]\+\)[[:space:]]*<') \
            && log_debug "Seraching countdown timer... 1"
        [ -z "$WAIT_TIME" ] && WAIT_TIME=$(echo "$PAGE" | parse_quiet '<span id="[[:alnum:]]\{6\}">' \
            '<span id="[[:alnum:]]\{6\}">[[:space:]]*\([0-9]\+\)[[:space:]]*<') \
            && log_debug "Seraching countdown timer... 2"
        [ -z "$WAIT_TIME" ] && WAIT_TIME=$(echo "$PAGE" | parse_quiet 'Wait.*second' \
            'Wait.*>[[:space:]]*\([0-9]\+\)[[:space:]]*<.*second') \
            && log_debug "Seraching countdown timer... 3"
        [ -z "$WAIT_TIME" ] && WAIT_TIME=$(echo "$PAGE" | parse_quiet 'countdown_str' \
            'countdown_str.*<span[^>]*id="[[:alnum:]]\+"[^>]*>[[:space:]]*\([0-9]\+\)[[:space:]]*<') \
            && log_debug "Seraching countdown timer... 4"

        [ -z "$WAIT_TIME" ] && PAGE_UNBREAK=$(echo "$PAGE" | replace $'\n' '')
        [ -z "$WAIT_TIME" ] && WAIT_TIME=$(echo "$PAGE_UNBREAK" | parse_quiet 'countdown_str' \
            'countdown_str.*<span[^>]*id="[[:alnum:]]\{6\}"[^>]*>[[:space:]]*\([0-9]\+\)[[:space:]]*<') \
            && log_debug "Seraching countdown timer... 5"
        [ -z "$WAIT_TIME" ] && WAIT_TIME=$(echo "$PAGE_UNBREAK" | parse_quiet 'countdown_str' \
            'countdown_str.*<span[^>]*id="[[:alnum:]]\+"[^>]*>[[:space:]]*\([0-9]\+\)[[:space:]]*<') \
            && log_debug "Seraching countdown timer... 6"

        [ -z "$WAIT_TIME" ] && log_error "Cannot locate countdown timer." && return $ERR_FATAL

        # Wait some more to avoid "Skipped countdown" error
        [ -n "$WAIT_TIME" ] && ((WAIT_TIME++))

        echo "$WAIT_TIME"
    fi
}

# Check and parse captcha
# $1: page
# stdout: data for curl
xfilesharing_handle_captcha() {
    local -r PAGE=$1
    local FORM_HTML=$2
    local FORM_CODE ID

    if match 'captchas\|code\|recaptcha\|solvemedia' "$PAGE"; then
        log_debug 'CAPTCHA found?'

        # Two default xfilesharing captchas - text and image
        # Text captcha solver - Copy/Paste from uptobox
        if match '/captchas/'  "$PAGE"; then
            local WI WORD ID CAPTCHA_URL CAPTCHA_IMG

            log_debug 'CAPTCHA: xfilesharing image'

            CAPTCHA_URL=$(echo "$PAGE" | parse_attr '/captchas/' src) || return
            CAPTCHA_IMG=$(create_tempfile '.jpg') || return

            curl -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || return

            WI=$(captcha_process "$CAPTCHA_IMG") || return
            { read WORD; read ID; } <<<"$WI"
            rm -f "$CAPTCHA_IMG"

            FORM_CODE="-d code=$WORD"

        elif match 'Enter code below:\|"captcha_code"' "$PAGE"; then
            local CODE OFFSET DIGIT DIGIT_N XCOORD LINE

            log_debug 'CAPTCHA: xfilesharing text'

            # Need to filter for bad non-tf8 characters, parse with offset glitches on such pages
            #  see enjoybox.in
            FORM_HTML=$(echo "$FORM_HTML" | iconv -c -t UTF-8)

            CODE=0
            OFFSET=48
            for (( DIGIT_N=1; DIGIT_N<=7; DIGIT_N+=2 )); do
                # direction:ltr
                DIGIT=$(echo "$FORM_HTML" | parse_quiet 'width:80px;height:26px;font:bold 13px Arial;background:#ccc;text-align:left;' '^&#\([[:digit:]]\+\);<' DIGIT_N+1) || return
                if [ -z $DIGIT ]; then
                    DIGIT=$(echo "$FORM_HTML" | parse 'width:80px;height:26px;font:bold 13px Arial;background:#ccc;text-align:left;' '^\([[:digit:]]\+\)<' DIGIT_N+1) || return
                    OFFSET=0
                fi
                XCOORD=$(echo "$FORM_HTML" | parse 'width:80px;height:26px;font:bold 13px Arial;background:#ccc;text-align:left;' '-left:\([[:digit:]]\+\)p' DIGIT_N) || return

                # Depending x, guess digit rank
                if (( XCOORD < 15 )); then
                    (( CODE = CODE + 1000 * (DIGIT-OFFSET) ))
                elif (( XCOORD < 30 )); then
                    (( CODE = CODE + 100 * (DIGIT-OFFSET) ))
                elif (( XCOORD < 50 )); then
                    (( CODE = CODE + 10 * (DIGIT-OFFSET) ))
                else
                    (( CODE = CODE + (DIGIT-OFFSET) ))
                fi
            done

            DIGIT_N="${#CODE}"
            if [ "$DIGIT_N" -lt 4 ]; then
                for (( ; DIGIT_N<4; DIGIT_N++ )); do
                    CODE="0$CODE"
                done
            fi

            FORM_CODE="-d code=$CODE"

        elif match 'recaptcha.*?k=' "$PAGE"; then
            local PUBKEY WCI CHALLENGE WORD ID

            log_debug 'CAPTCHA: reCaptcha'

            # http://www.google.com/recaptcha/api/challenge?k=
            # http://api.recaptcha.net/challenge?k=
            PUBKEY=$(echo "$PAGE" | parse 'recaptcha.*?k=' '?k=\([[:alnum:]_-.]\+\)') || return
            WCI=$(recaptcha_process $PUBKEY) || return
            { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

            FORM_CODE="-d recaptcha_challenge_field=$CHALLENGE -d recaptcha_response_field=$WORD"

        elif match 'solvemedia\.com.*?k=' "$PAGE"; then
            local PUBKEY RESP CHALLENGE ID

            log_debug 'CAPTCHA: Solve Media'

            # solvemedia.com/papi/challenge.script?k=
            PUBKEY=$(echo "$PAGE" | parse 'solvemedia\.com.*?k=' '?k=\([[:alnum:]_-.]\+\)') || return
            log_debug "Solvemedia pubkey: '$PUBKEY'"
            RESP=$(solvemedia_captcha_process $PUBKEY) || return
            { read CHALLENGE; read ID; } <<< "$RESP"

            FORM_CODE="-d adcopy_response=manual_challenge --data-urlencode adcopy_challenge=$CHALLENGE"
        fi

        [ -z "$FORM_CODE" ] && log_debug 'False alarm.'
        [ -n "$FORM_CODE" ] && log_debug "CAPTCHA data: $FORM_CODE"
    fi

    if [ -n "$FORM_CODE" ]; then
        echo "$FORM_CODE"
        echo "$ID"
    fi

    return 0
}

# Output a file download URL
# $1: cookie file
# $2: file hosting url
# stdout: real file download link
xfilesharing_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL=$(basename_url "$URL")
    local FORM_ACTION=$URL
    local PAGE TYPE WAIT_TIME FILE_URL ERROR CODE TIME NEW_PAGE=1
    local LOCATION EXTRA
    local FORM_DATA FORM_CAPTCHA FORM_PASSWORD

    if [ -n "$AUTH" ]; then
        xfilesharing_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    for TRY in 1 2; do
        PAGE=$(curl -i -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' "$URL" | \
            strip_html_comments) || return

        # billionuploads, goonshare.net
        if match 'DDoS protection by CloudFlare\|CloudFlare Ray ID' "$PAGE"; then
            local FORM_DDOS FORM_DDOS_VC FORM_DDOS_ACTION DDOS_CHLNG DOMAIN

            log_debug "CloudFlare DDoS protection detected."

            if match 'The web server reported a bad gateway error' "$PAGE"; then
                log_error 'CloudFlare bad gateway. Try again later.'
                #return $ERR_LINK_TEMP_UNAVAILABLE
                return $ERR_FATAL
            fi

            FORM_DDOS=$(grep_form_by_id "$PAGE" 'challenge-form') || return
            FORM_DDOS_ACTION=$(echo "$PAGE" | parse_form_action) || return
            FORM_DDOS_VC=$(echo "$FORM_DDOS" | parse_form_input_by_name 'jschl_vc') || return
            DDOS_CHLNG=$(echo "$PAGE" | parse 'a.value = ' 'a.value = \([^;]\+\)') || return
            DOMAIN=$(echo "$BASE_URL" | parse . '^https\?://\(.*\)$')
            DDOS_CHLNG=$(( ($DDOS_CHLNG) + ${#DOMAIN} ))

            wait 6 || return

            PAGE=$(curl -i -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' -G \
                -e "$URL" \
                -d "jschl_vc=$FORM_DDOS_VC" \
                -d "jschl_answer=$DDOS_CHLNG" \
                "$BASE_URL$FORM_DDOS_ACTION" | \
                strip_html_comments) || return
        else
            break
        fi
    done

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)
    if [ -n "$LOCATION" ]; then
        if [ $(basename_url "$LOCATION") = "$LOCATION" ]; then
            FORM_ACTION="$BASE_URL/$LOCATION"
        elif match 'op=login' "$LOCATION"; then
            log_error "You must be registered to download."
            return $ERR_LINK_NEED_PERMISSIONS
        else
            FORM_ACTION="$LOCATION"
        fi
        log_debug "New form action: '$FORM_ACTION'"
    fi
    #MODULE_XFILESHARING_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=( -e "$FORM_ACTION" )

    # Parse imagehosting
    RE_IMG="<img[^>]*src=[^>]*\(/files/\|/i/\)[^'\"[:space:]>]*\(t(_\|[^_])\|[^t]\)\."
    if match "$RE_IMG" "$PAGE"; then
        IMG_URL=$(echo "$PAGE" | parse_attr_quiet "$RE_IMG" 'src')
        IMG_ALT=$(echo "$PAGE" | parse_attr_quiet "$IMG_URL" 'alt')
        IMG_TITLE=$(echo "$PAGE" | parse_tag_quiet '<[Tt]itle>' '[Tt]itle')
        IMG_ID=$(echo "$URL" | parse_quiet . '[^/]/\([[:alnum:]]\{12\}\)\(/\|$\)')
        # Ignore video thumbnails
        if [ -n "$IMG_URL" ]; then
            if ( [ -n "$IMG_ALT" ] && match "$IMG_ALT" "$IMG_TITLE" ) || \
            match "$IMG_ID" "$IMG_URL"; then
                log_debug 'Image hosting detected'

                echo "$IMG_URL"
                [ -n "$IMG_ALT" ] && echo "$IMG_ALT"
                return 0
            fi
        fi
    fi

    xfilesharing_parse_error "$PAGE" || return

    # Streaming sites like to pack player scripts and place them where they like
    xfilesharing_parse_streaming "$PAGE" "$FORM_ACTION" && return 0

    # First form sometimes absent
    FORM_DATA=$(xfilesharing_parse_form1 "$PAGE") || return
    if [ -n "$FORM_DATA" ]; then
        { read -r FILE_NAME_TMP; } <<<"$FORM_DATA"
        [ -n "$FILE_NAME_TMP" ] && FILE_NAME=$(echo "$FILE_NAME_TMP" | parse . '=\(.*\)$')

        WAIT_TIME=$(xfilesharing_handle_countdown "$PAGE") || return
        if [ -n "$WAIT_TIME" ]; then
            wait $WAIT_TIME || return
        fi

        PAGE=$(xfilesharing_commit_step1 "$PAGE" "$COOKIE_FILE" "$FORM_ACTION" "$FORM_DATA") || return

        # To avoid double check for errors or streaming if page not updated
        NEW_PAGE=1
    else
        log_debug 'Form 1 omitted.'
    fi

    if [ $NEW_PAGE = 1 ]; then
        xfilesharing_parse_error "$PAGE" || return
        xfilesharing_parse_streaming "$PAGE" "$FORM_ACTION" "$FILE_NAME" && return 0
        NEW_PAGE=0
    fi

    FORM_DATA=$(xfilesharing_parse_form2 "$PAGE") || return
    if [ -n "$FORM_DATA" ]; then
        { read -r FILE_NAME_TMP; } <<<"$FORM_DATA"
        [ -n "$FILE_NAME_TMP" ] && FILE_NAME=$(echo "$FILE_NAME_TMP" | parse . '=\(.*\)$')

        WAIT_TIME=$(xfilesharing_handle_countdown "$PAGE") || return

        # If password or captcha is too long :)
        [ -n "$WAIT_TIME" ] && TIME=$(date +%s)

        if match '"password"' "$FORM_DATA"; then
            log_debug 'File is password protected'
            if [ -z "$LINK_PASSWORD" ]; then
                LINK_PASSWORD=$(prompt_for_password) || return
                FORM_PASSWORD="-d password=$LINK_PASSWORD"
            fi
        fi

        CAPTCHA_DATA=$(xfilesharing_handle_captcha "$PAGE" "$FORM_DATA") || return
        { read FORM_CAPTCHA; read CAPTCHA_ID; } <<<"$CAPTCHA_DATA"

        if [ -n "$WAIT_TIME" ]; then
            TIME=$(($(date +%s) - $TIME))
            if [ $TIME -lt $WAIT_TIME ]; then
                WAIT_TIME=$((WAIT_TIME - $TIME))
                wait $WAIT_TIME || return
            fi
        fi

        PAGE=$(xfilesharing_commit_step2 "$PAGE" "$COOKIE_FILE" "$FORM_ACTION" "$FORM_DATA" \
            "$FORM_PASSWORD" "$FORM_CAPTCHA") || return

        # In case of download-after-post system or some complicated link parsing
        #  that requires additional data and page rquests (like uploadc or up.lds.net)
        if match_remote_url $(echo "$PAGE" | first_line); then
            { read FILE_URL; read FILE_NAME_TMP; read EXTRA; } <<<"$PAGE"
            [ -n "$FILE_NAME_TMP" ] && FILE_NAME="$FILE_NAME_TMP"
            [ -n "$EXTRA" ] && eval "$EXTRA"
        else
            NEW_PAGE=1
        fi
    else
        log_debug 'Form 2 omitted.'
    fi

    if [ -z "$FILE_URL" ]; then
        if [ $NEW_PAGE = 1 ]; then
            xfilesharing_parse_error "$PAGE" "$CAPTCHA_ID" || return
            xfilesharing_parse_streaming "$PAGE" "$FORM_ACTION" "$FILE_NAME" && return 0
        fi

        # I think it would be correct to use parse fucntion to parse only,
        #  but not make any additional requests
        FILE_DATA=$(xfilesharing_parse_final_link "$PAGE" "$FILE_NAME") || return
        { read FILE_URL; read FILE_NAME_TMP; read EXTRA; } <<<"$FILE_DATA"
        [ -n "$FILE_NAME_TMP" ] && FILE_NAME="$FILE_NAME_TMP"
        [ -n "$EXTRA" ] && eval "$EXTRA"
    fi

    if match_remote_url "$FILE_URL"; then
        if [ -n "$FORM_CODE" -a -n "$CAPTCHA_ID" ]; then
            log_debug 'Correct captcha'
            captcha_ack $CAPTCHA_ID
        fi

        # hulkload, queenshare adflying links
        if match '^http://adf\.ly/.*http://' "$FILE_URL"; then
            log_debug 'Aflyed link detected.'
            FILE_URL=$(echo "$FILE_URL" | parse . '^http://adf\.ly/.*\(http://.*\)$')
        fi

        echo "$FILE_URL"
        [ -n "$FILE_NAME" ] && echo "$FILE_NAME"
        return 0
    fi

    log_debug 'Link not found'

    # Can be wrong captcha, some sites (cramit.in) do not return any error message
    if [ -n "$FORM_CODE" ]; then
        log_debug 'Wrong captcha'
        [ -n "$CAPTCHA_ID" ] && captcha_nack $CAPTCHA_ID
        return $ERR_CAPTCHA
    else
        log_error 'Unexpected content.'
    fi

    return $ERR_FATAL
}

# Upload a file to file hosing
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
xfilesharing_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL=$HOSTING
    local PAGE FILE_SIZE MAX_SIZE DEL_CODE FILE_ID UPLOAD_ID USER_TYPE
    local PUBLIC_FLAG=0

    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif [ -n "$PREMIUM" ]; then
            log_error 'You must be registered to create premium-only downloads.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    if match_remote_url "$FILE"; then
        # Remote upload requires registration
        if test -z "$AUTH"; then
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    else
        # 2000 MiB limit for account users
        if test "$AUTH"; then
            MAX_SIZE=1048576000 # 1000 MiB
        else
            MAX_SIZE=2097152000 # 2000 MiB
        fi

        FILE_SIZE=$(get_filesize "$FILE")
        if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
            log_debug "File is bigger than $MAX_SIZE"
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    if test "$AUTH"; then
        xfilesharing_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" >/dev/null || return

        if ! match_remote_url "$FILE"; then
            xfilesharing_check_freespace "$FILE_SIZE" "$COOKIE_FILE" "$BASE_URL" || return
        fi

        if [ -n "$FOLDER" ]; then
            FOLDER_ID=$(xfilesharing_check_folder "$FOLDER" "$COOKIE_FILE" "$BASE_URL") || return
            log_debug "Folder ID: '$FOLDER_ID'"
        fi

        USER_TYPE='reg'
    else
        USER_TYPE='anon'
    fi

    [ -z "$PRIVATE_FILE" ] && PUBLIC_FLAG=1

    PAGE=$(curl -c "$COOKIE_FILE" -b 'lang=english' -b "$COOKIE_FILE" "$BASE_URL") || return

    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_TMP_SRV
    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_FORM_TMP_SRV=$(echo "$FORM_HTML" | parse_form_input_by_name 'srv_tmp_url') || return
    FORM_UTYPE=$(echo "$FORM_HTML" | parse_form_input_by_name 'upload_type')
    # Will be empty on anon upload
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id')

    # Initial js code:
    # for (var i = 0; i < 12; i++) UID += '' + Math.floor(Math.random() * 10);
    # form_action = form_action.split('?')[0] + '?upload_id=' + UID + '&js_on=1' + '&utype=' + utype + '&upload_type=' + upload_type;
    # upload_type: file, url
    # utype: anon, reg
    UPLOAD_ID=$(random d 12)

    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -H 'Expect: ' \
        -F 'upload_type=file' \
        -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        -F "file_1=@/dev/null;filename=" \
        --form-string "file_0_descr=$DESCRIPTION" \
        -F "file_0_public=$PUBLIC_FLAG" \
        --form-string "link_rcpt=$TOEMAIL" \
        --form-string "link_pass=$LINK_PASSWORD" \
        -F 'tos=1' \
        -F 'submit_btn=' \
        "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=$FORM_UTYPE" | \
        break_html_lines) || return

    local OP FILE_CODE STATE
    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return

    OP=$(echo "$FORM_HTML" | parse_tag 'op' 'textarea')
    FILE_CODE=$(echo "$FORM_HTML" | parse_tag 'fn' 'textarea')
    STATE=$(echo "$FORM_HTML" | parse_tag 'st' 'textarea')

    log_debug "File Code: '$FILE_CODE'"
    log_debug "State: '$STATE'"

    if [ "$STATE" = 'OK' ]; then
        log_debug 'Upload successfull.'
    elif [ "$STATE" = 'unallowed extension' ]; then
        log_error 'File extension is forbidden.'
        return $ERR_FATAL
    elif [ "$STATE" = 'file is too big' ]; then
        log_error 'Uploaded file is too big.'
        return $ERR_SIZE_LIMIT_EXCEEDED
    elif [ "$STATE" = 'not enough disk space on your account' ]; then
        log_error 'Account space exceeded.'
        return $ERR_SIZE_LIMIT_EXCEEDED
    else
        log_error "Unknown upload state: $STATE"
        return $ERR_FATAL
    fi

    # Get killcode, file_id and generate links
    # Note: At this point we know the upload state is "OK" due to "if" above
    PAGE=$(curl -b "$COOKIE_FILE" \
        -F "fn=$FILE_CODE" \
        -F "st=$STATE" \
        -F "op=$OP" \
        --form-string "link_rcpt=$TOEMAIL" \
        "$BASE_URL") || return

    DEL_CODE=$(echo "$PAGE" | parse 'killcode=' 'killcode=\([[:alnum:]]\+\)') || return
    FILE_ID=$(echo "$PAGE" | parse 'id="ic[0-9]-' 'id="ic[0-9]-\([0-9]\+\)') || return

    log_debug "File ID: '$FILE_ID'"

    LINK="$BASE_URL/$FILE_CODE"
    DEL_LINK="$BASE_URL/$FILE_CODE?killcode=$DEL_CODE"

    # Move file to a folder?
    if [ -n "$FOLDER" ]; then
        log_debug 'Moving file...'

        # Source folder ("fld_id") is always root ("0") for newly uploaded files
        PAGE=$(curl -b "$COOKIE_FILE" -i \
            -F 'op=my_files' \
            -F 'fld_id=0' \
            -F "file_id=$FILE_ID" \
            -F "to_folder=$FOLDER_ID" \
            -F 'to_folder_move=Move files' \
            "$BASE_URL") || return

        PAGE=$(echo "$PAGE" | grep_http_header_location_quiet)
        match '?op=my_files' "$PAGE" || log_error 'Could not move file. Site update?'
    fi

    # Set premium only flag
    if [ -n "$PREMIUM" ]; then
        log_debug 'Setting premium flag...'

        PAGE=$(curl -b "$COOKIE_FILE" -G \
            -d 'op=my_files' \
            -d "file_id=$FILE_ID" \
            -d 'set_premium_only=true' \
            -d 'rnd='$(random js) \
            "$BASE_URL") || return

        [ "$PAGE" != "\$\$('tpo$FILE_ID').className='pub';" ] && \
            log_error 'Could not set premium only flag. Site update?'
    fi

    echo "$LINK"
    echo "$DEL_LINK"
}

# Delete a file uploaded to file hosting
# $1: cookie file (unused here)
# $2: delete url
xfilesharing_delete() {
    local -r URL=$2
    local -r BASE_URL=$XF_BASE_URL
    local PAGE FILE_ID FILE_DEL_ID

    if ! match 'killcode=[[:alnum:]]\+' "$URL"; then
        log_error 'Invalid URL format'
        return $ERR_BAD_COMMAND_LINE
    fi

    FILE_ID=$(parse . "^$BASE_URL/\([[:alnum:]]\+\)" <<< "$URL")
    FILE_DEL_ID=$(parse . 'killcode=\([[:alnum:]]\+\)$' <<< "$URL")

    PAGE=$(curl -b 'lang=english' -e "$URL" \
        -d 'op=del_file' \
        -d "id=$FILE_ID" \
        -d "del_id=$FILE_DEL_ID" \
        -d 'confirm=yes' \
        "$BASE_URL/") || return

    if match 'File deleted successfully' "$PAGE"; then
        return 0
    elif match 'No such file exist' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match 'Wrong Delete ID' "$PAGE"; then
        log_error 'Wrong delete ID'
    fi

    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: file hosting url
# $3: requested capability list
# stdout: 1 capability per line
xfilesharing_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -b 'lang=english' "$URL") || return

    if match 'File Not Found\|file was removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_REFERER FORM_METHOD_F
    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname') || return
    FORM_REFERER=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'referer')
    FORM_METHOD_F=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')

    PAGE=$(curl -b 'lang=english' \
        -d "op=$FORM_OP" \
        -d "usr_login=$FORM_USR" \
        -d "id=$FORM_ID" \
        --data-urlencode "fname=$FORM_FNAME" \
        -d "referer=$FORM_REFERER" \
        -d "method_free=$FORM_METHOD_F" \
        "$URL") || return

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$FORM_FNAME" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'Size:' \
            '<td>\(.*\)$' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a file hositng web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
xfilesharing_list() {
    local -r URL=$1
    local -r REC=$2
    local RET=$ERR_LINK_DEAD
    local PAGE LINKS NAMES ERROR PAGE_NUMBER LAST_PAGE

    PAGE=$(curl -b 'lang=english' "$URL") || return

    ERROR=$(echo "$PAGE" | parse_tag_quiet 'class="err"' 'font')
    if [ "$ERROR" = 'No such user exist' ]; then
        return $ERR_LINK_DEAD
    elif [ -n "$ERROR" ]; then
        log_error "Remote error: $ERROR"
        return $ERR_FATAL
    fi

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'class="link"' 'href')
    NAMES=$(echo "$PAGE" | parse_all_tag_quiet 'class="link"' 'a')

    # Parse page buttons panel if exist
    LAST_PAGE=$(echo "$PAGE" | parse_tag_quiet 'class="paging"' 'div' | break_html_lines | \
        parse_all_quiet . 'page=\([0-9]\+\)')

    if [ -n "$LAST_PAGE" ];then
        # The last button is 'Next', last page button right before
        LAST_PAGE=$(echo "$LAST_PAGE" | delete_last_line | last_line)

        for (( PAGE_NUMBER=2; PAGE_NUMBER<=LAST_PAGE; PAGE_NUMBER++ )); do
            log_debug "Listing page #$PAGE_NUMBER"

            PAGE=$(curl -G \
                -d "page=$PAGE_NUMBER" \
                "$URL") || return

            LINKS=$LINKS$'\n'$(echo "$PAGE" | parse_all_attr_quiet 'class="link"' 'href')
            NAMES=$NAMES$'\n'$(echo "$PAGE" | parse_all_tag_quiet 'class="link"' 'a')
        done
    fi

    list_submit "$LINKS" "$NAMES" && RET=0

    # Are there any subfolders?
    if [ -n "$REC" ]; then
        local FOLDERS FOLDER

        FOLDERS=$(echo "$PAGE" | parse_all_attr_quiet 'folder2.gif' 'href') || return

        # First folder can be parent folder (". .") - drop it to avoid infinite loops
        FOLDER=$(echo "$PAGE" | parse_tag_quiet 'folder2.gif' 'b') || return
        [ "$FOLDER" = '. .' ] && FOLDERS=$(echo "$FOLDERS" | delete_first_line)

        while read FOLDER; do
            [ -z "$FOLDER" ] && continue
            log_debug "Entering sub folder: $FOLDER"
            xfilesharing_list "$FOLDER" "$REC" && RET=0
        done <<< "$FOLDERS"
    fi

    return $RET
}
