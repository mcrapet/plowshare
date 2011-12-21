#!/bin/bash
#
# mediafire.com module
# Copyright (c) 2011 Plowshare team
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

MODULE_MEDIAFIRE_REGEXP_URL="http://\(www\.\)\?mediafire\.com/"

MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS="
LINK_PASSWORD,p:,link-password:,PASSWORD,Used in password-protected files"
MODULE_MEDIAFIRE_DOWNLOAD_RESUME=no
MODULE_MEDIAFIRE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_MEDIAFIRE_UPLOAD_OPTIONS=""
MODULE_MEDIAFIRE_LIST_OPTIONS=""

# Output a mediafire file download URL
# $1: cookie file
# $2: mediafire.com url
# stdout: real file download link
mediafire_download() {
    eval "$(process_options mediafire "$MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL="$2"
    local LOCATION PAGE FILE_URL FILENAME

    detect_javascript || return

    LOCATION=$(curl --head "$URL" | grep_http_header_location) || return

    if match '^http://download' "$LOCATION"; then
        log_notice "direct download"
        echo "$LOCATION"
        return 0
    elif match 'errno=999$' "$LOCATION"; then
        return $ERR_LINK_NEED_PERMISSIONS
    elif match 'errno=320$' "$LOCATION"; then
        return $ERR_LINK_DEAD
    elif match 'errno=378$' "$LOCATION"; then
        return $ERR_LINK_DEAD
    elif match 'errno=' "$LOCATION"; then
        log_error "site redirected with an unknown error"
        return $ERR_FATAL
    fi

    PAGE=$(curl -L -c $COOKIEFILE "$URL" | break_html_lines) || return

    if test "$CHECK_LINK"; then
        match 'class="download_file_title"' "$PAGE" && return 0
        return $ERR_LINK_DEAD
    fi

    # reCaptcha
    if match '<textarea name="recaptcha_challenge_field"' "$PAGE"; then

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LextQUAAAAAALlQv0DSHOYxqF3DftRZxA5yebEe'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        PAGE=$(curl -b "$COOKIEFILE" --data \
            "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" \
            -H "X-Requested-With: XMLHttpRequest" --referer "$URL" \
            "$URL" | break_html_lines) || return

        # You entered the incorrect keyword below, please try again!
        if match 'incorrect keyword' "$PAGE"; then
            recaptcha_nack $ID
            log_error "wrong captcha"
            return $ERR_CAPTCHA
        fi

        recaptcha_ack $ID
        log_debug "correct captcha"
    fi

    # When link is password protected, there's no facebook "I like" box (iframe).
    # Use that trick!
    if ! match 'facebook.com/plugins/like' "$PAGE"; then
        log_error "Password-protected links are not supported"
        return $ERR_LINK_PASSWORD_REQUIRED

        # FIXME
        #log_debug "File is password protected"
        #if [ -z "$LINK_PASSWORD" ]; then
        #    LINK_PASSWORD=$(prompt_for_password) || return
        #fi
        #PAGE=$(curl -L -b "$COOKIEFILE" --data "downloadp=$LINK_PASSWORD" "$URL" | break_html_lines) || return
    fi

    FILE_URL=$(get_ofuscated_link "$PAGE" "$COOKIEFILE") || return
    FILENAME=$(curl -I "$FILE_URL" | grep_http_header_content_disposition) || return

    echo "$FILE_URL"
    test -n "$FILENAME" && echo "$FILENAME"
}

get_ofuscated_link() {
    local PAGE="$1"
    local COOKIEFILE="$2"
    local BASE_URL='http://www.mediafire.com'

    local PAGE_JS FNAME ZINDEX_MOD ZINDEX_LINKS

    # One single line
    PAGE_JS=$(echo "$PAGE" | grep 'function SaveFileToMyAccount') || {
        log_error "cannot find main javascript code";
        return $ERR_FATAL;
    }

    FNAME=$(echo "$PAGE_JS" | parse_all 'function' 'function \([[:alnum:]]\+\)()' | first_line) ||
        { log_error "cannot get JS function name"; return $ERR_FATAL; }

    ZINDEX_MOD=$(echo "
        ax = dC = jQuery = setTimeout = DoShow = LoadTemplatesFromSource = function() {};
        window = {};
        old_eval = eval;
        eval = function(code) {
            if(code.match(/\.download_link/)) {
              print(code);
            } else {
              return old_eval(code);
            }
        };
        fu = 1;
        $PAGE_JS;
        $FNAME();
    " | js | parse 'z-index' 'z-index.*[[:space:]]*%[[:space:]]*\([[:digit:]]\+\)') ||
        { log_error "cannot get z-index modulo"; return $ERR_FATAL; }

    ZINDEX_LINKS=$(echo "$PAGE" | sed "s/<div/\n<div/g" | grep 'class="download_link"' |
            sed 's/.*z-index:\([[:digit:]]\+\).*href="\([^"]\+\)".*/\1 \2/')
    echo "$ZINDEX_LINKS" | while read ZINDEX URL; do
        echo "$(($ZINDEX % $ZINDEX_MOD)) $URL"
    done | sort -rn | first_line | cut -d" " -f2-
}

# Upload a file to mediafire
# $1: cookie file (unused)
# $2: input file (with full path)
# $3: remote filename
# stdout: mediafire.com download link
mediafire_upload() {
    local FILE="$2"
    local DESTFILE="$3"
    local BASE_URL="http://www.mediafire.com"

    log_debug "Get uploader configuration"
    XML=$(curl "$BASE_URL/basicapi/uploaderconfiguration.php?$$" | break_html_lines) ||
            { log_error "Couldn't upload file!"; return 1; }

    local UKEY=$(echo "$XML" | parse_quiet ukey '<ukey>\([^<]*\)<\/ukey>')
    local USER=$(echo "$XML" | parse_quiet user '<user>\([^<]*\)<\/user>')
    local TRACK_KEY=$(echo "$XML" | parse_quiet trackkey '<trackkey>\([^<]*\)<\/trackkey>')
    local FOLDER_KEY=$(echo "$XML" | parse_quiet folderkey '<folderkey>\([^<]*\)<\/folderkey>')
    local MFUL_CONFIG=$(echo "$XML" | parse_quiet MFULConfig '<MFULConfig>\([^<]*\)<\/MFULConfig>')

    log_debug "trackkey: $TRACK_KEY"
    log_debug "folderkey: $FOLDER_KEY"
    log_debug "ukey: $UKEY"
    log_debug "MFULConfig: $MFUL_CONFIG"

    if [ -z "$UKEY" -o -z "$TRACK_KEY" -o -z "$FOLDER_KEY" -o -z "$MFUL_CONFIG" -o -z "$USER" ]; then
        log_error "Can't parse uploader configuration!"
        return $ERR_FATAL
    fi

    log_debug "Uploading file"
    local UPLOAD_URL="$BASE_URL/douploadtoapi/?track=$TRACK_KEY&ukey=$UKEY&user=$USER&uploadkey=$FOLDER_KEY&upload=0"

    # HTTP header "Expect: 100-continue" seems to confuse server
    XML=$(curl_with_log -0 \
        -F "Filename=$DESTFILE" \
        -F "Upload=Submit Query" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        --user-agent "Shockwave Flash" \
        --referer "$BASE_URL/basicapi/uploaderconfiguration.php?$$" "$UPLOAD_URL") || return

    # Example of answer:
    # <?xml version="1.0" encoding="iso-8859-1"?>
    # <response>
    #  <doupload>
    #   <result>0</result>
    #   <key>sf22seu6p7d</key>
    #  </doupload>
    # </response>
    local UPLOAD_KEY=$(echo "$XML" | parse_quiet key '<key>\([^<]*\)<\/key>')
    log_debug "key: $UPLOAD_KEY"

    if [ -z "$UPLOAD_KEY" ]; then
        log_error "Can't get upload key!"
        return $ERR_FATAL
    fi

    log_debug "Polling for status update"

    local TRY=0
    local QUICK_KEY=""
    while [ "$TRY" -lt 3 ]; do
        (( ++TRY ))
        XML=$(curl "$BASE_URL/basicapi/pollupload.php?key=$UPLOAD_KEY&MFULConfig=$MFUL_CONFIG")

        if match '<description>No more requests for this key</description>' "$XML"; then
            QUICK_KEY=$(echo "$XML" | parse_quiet quickkey '<quickkey>\([^<]*\)<\/quickkey>')
            break
        fi
        wait 2 seconds || return
    done

    if [ -z "$QUICK_KEY" ]; then
        log_error "Can't get quick key!"
        return $ERR_FATAL
    fi

    echo "$BASE_URL/?$QUICK_KEY"
}

# List a mediafire shared file folder URL
# $1: mediafire folder url (http://www.mediafire.com/?sharekey=...)
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
mediafire_list() {
    local URL="$1"

    PAGE=$(curl "$URL" | break_html_lines_alt)

    if ! match '/js/myfiles.php/' "$PAGE"; then
        log_error "not a shared folder"
        return $ERR_FATAL
    fi

    local JS_URL=$(echo "$PAGE" | parse 'LoadJS(' '("\(\/js\/myfiles\.php\/[^"]*\)')
    local DATA=$(curl "http://mediafire.com$JS_URL" | sed "s/\([)']\);/\1;\n/g")

    # get number of files
    NB=$(echo "$DATA" | parse '^var oO' "'\([[:digit:]]*\)'")

    log_debug "There is $NB file(s) in the folder"

    # print filename as debug message & links (stdout)
    # es[0]=Array('1','1',3,'te9rlz5ntf1','82de6544620807bf025c12bec1713a48','my_super_file.txt','14958589','14.27','MB','43','02/13/2010', ...
    DATA=$(echo "$DATA" | grep 'es\[' | tr -d "'" | delete_last_line)
    while IFS=, read -r _ _ _ FID _ FILENAME _; do
        log_debug "$FILENAME"
        echo "http://www.mediafire.com/?$FID"
    done <<< "$DATA"

    # Alternate (more portable?) version:
    #
    # while read LINE; do
    #     FID=$(echo "$LINE" | cut -d, -f4)
    #     FILENAME=$(echo "$LINE" | cut -d, -f6)
    #     log_debug "$FILENAME"
    #     echo "http://www.mediafire.com/?$FID"
    # done <<< "$DATA"

    return 0
}
