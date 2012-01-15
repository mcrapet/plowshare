#!/bin/bash
#
# multiupload.com module
# Copyright (c) 2011-2012 Plowshare team
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

MODULE_MULTIUPLOAD_REGEXP_URL="http://\(www\.\)\?multiupload\.com/"

MODULE_MULTIUPLOAD_DOWNLOAD_OPTIONS=""
MODULE_MULTIUPLOAD_DOWNLOAD_RESUME=yes
MODULE_MULTIUPLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused

MODULE_MULTIUPLOAD_UPLOAD_OPTIONS="
DESCRIPTION,d:,description:,DESCRIPTION,Set file description
AUTH,a:,auth:,USER:PASSWORD,User account
FROMEMAIL,,email-from:,EMAIL,<From> field for notification email
TOEMAIL,,email-to:,EMAIL,<To> field for notification email
NO_HOTFILE,,no-hf,,Exclude Hotfile.com from host list"
MODULE_MULTIUPLOAD_LIST_OPTIONS=""

# Output a multiupload.com "direct download" link
# $1: cookie file (unused here)
# $2: 2shared url
# stdout: real file download link
multiupload_download() {
    local URL="$2"
    local PAGE FID JSON FILE_URL

    PAGE=$(curl "$URL" | break_html_lines) || return

    # Unfortunately, the link you have clicked is not available.
    if match "is not available" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # reCaptcha
    # <a href="javascript:directdownload();" onclick="launchpopunder();" id="dlbutton">
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6Ldk3ssSAAAAAGhnqt8O_xgLW-NVR0cqwOON1Pg3'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    FID=$(echo "$PAGE" | parse 'checkCaptcha()' "'\(\?c=[^']\+\)") || return
    JSON=$(curl --data \
        "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" \
        -H "X-Requested-With: XMLHttpRequest" --referer "$URL" \
        "$URL$FID") || return

    # {"response":"0"}
    if match '"response"' "$JSON"; then
        recaptcha_nack $ID
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    recaptcha_ack $ID
    log_debug "correct captcha"

    # {"href":"http:\/\/www44.multiupload.com:81\/files\/ ... "}
    FILE_URL=$(echo "$JSON" | parse 'href' '"href"[[:space:]]*:[[:space:]]*"\([^"]*\)"') || return

    echo "$FILE_URL"
}

# Upload a file to multiupload.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: multiupload.com download link
#
# Note: No external premium account (RS, MU, ...) support.
multiupload_upload() {
    eval "$(process_options multiupload "$MODULE_MULTIUPLOAD_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local FILE="$2"
    local DESTFILE="$3"
    local BASE_URL='http://www.multiupload.com'
    local PAGE FORM_HTML FORM_URL FORM_U FORM_X DLID

    if test "$AUTH"; then
        local USER PASSWORD LOGIN_RESULT

        USER="${AUTH%%:*}"
        PASSWORD="${AUTH#*:}"

        if [ "$AUTH" = "$PASSWORD" ]; then
            PASSWORD=$(prompt_for_password) || return $ERR_LOGIN_FAILED
        fi

        LOGIN_RESULT=$(curl -L -c "$COOKIEFILE" -F "username=$USER" \
                -F "password=$PASSWORD" "$BASE_URL/login") || return

        if ! match '>Log out<' "$LOGIN_RESULT"; then
            return $ERR_LOGIN_FAILED
        fi
    fi

    PAGE=$(curl -b "$COOKIEFILE" "$BASE_URL" | break_html_lines_alt) || return

    FORM_HTML=$(grep_form_by_id "$PAGE" uploadfrm)
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action)
    FORM_U=$(echo "$FORM_HTML" | parse_form_input_by_name 'u')
    FORM_X=$(echo "$FORM_HTML" | parse_form_input_by_name 'X-Progress-ID')

    log_debug "Upload ID: $FORM_U / ${FORM_X:-No Progress-ID}"

    # List:
    # service_1 : MU (Megaupload)
    # service_5 : RS (Rapidshare)
    # service_6 : ZS (Zshare)
    # service_7 : DF (DepositFiles)
    # service_9 : HF (HotFile)
    # service_10 : UP (Uploading.com)
    # service_14 : FS (FileServe)
    # service_15 : FC (FileSonic)
    # service_16 : UK (UploadKing)
    # service_17 : UH (UploadHere)
    # service_18 : WU (Wupload)
    #
    # Changes:
    # - 2011.09.12: MU, UK, DF, UH, HF, UP
    # - 2011.10.29: MU, UK, DF, HF, UH, ZS, FC, FS, WU

    # Keep default settings
    local form_site1=$(echo "$FORM_HTML" | parse_form_input_by_name 'service_1')
    local form_site2=$(echo "$FORM_HTML" | parse_form_input_by_name 'service_16')
    local form_site3=$(echo "$FORM_HTML" | parse_form_input_by_name 'service_7')
    local form_site4=$(echo "$FORM_HTML" | parse_form_input_by_name 'service_9')
    local form_site5=$(echo "$FORM_HTML" | parse_form_input_by_name 'service_17')
    local form_site6=$(echo "$FORM_HTML" | parse_form_input_by_name 'service_6')
    local form_site7=$(echo "$FORM_HTML" | parse_form_input_by_name 'service_15')
    local form_site8=$(echo "$FORM_HTML" | parse_form_input_by_name 'service_14')
    local form_site9=$(echo "$FORM_HTML" | parse_form_input_by_name 'service_18')

    test "$NO_HOTFILE" && form_site4=''

    # Notes:
    # - file0 can go to file9 (included)
    # - fetchfield0 & fetchdesc0 are not used here
    # - there is a special variable "rsaccount" for RS (can be "C" or "P")
    PAGE=$(curl_with_log -0 -b "$COOKIEFILE" \
        -F "file0=@$FILE;filename=$DESTFILE" \
        -F "description_0=$DESCRIPTION" \
        -F "X-Progress-ID=$FORM_X" \
        -F "u=$FORM_U" \
        -F "service_1=$form_site1"  -F "username_1="  -F "password_1="  -F "remember_1="  \
        -F "service_16=$form_site2" -F "username_16=" -F "password_16=" -F "remember_16=" \
        -F "service_7=$form_site3"  -F "username_7="  -F "password_7="  -F "remember_7="  \
        -F "service_9=$form_site4"  -F "username_9="  -F "password_9="  -F "remember_9="  \
        -F "service_17=$form_site5" -F "username_17=" -F "password_17=" -F "remember_17=" \
        -F "service_6=$form_site6"  -F "username_10=" -F "password_10=" -F "remember_10=" \
        -F "service_15=$form_site7" -F "username_15=" -F "password_15=" -F "remember_15=" \
        -F "service_14=$form_site8" -F "username_14=" -F "password_14=" -F "remember_14=" \
        -F "service_18=$form_site9" -F "username_18=" -F "password_18=" -F "remember_18=" \
        -F "fromemail=$FROMEMAIL" -F "toemail=$TOEMAIL" $FORM_URL) || return

    DLID=$(echo "$PAGE" | parse_quiet 'downloadid' 'downloadid":"\([^"]*\)')
    log_debug "Download ID: $DLID"

    if [ -z "$DLID" ]; then
        log_error "Unexpected result (site updated?)"
        return $ERR_FATAL
    fi

    echo "$BASE_URL/$DLID"
}

# List multiple hosting site links
# $1: multiupload.com link
# $2: recurse subfolders (non sense for this module)
# stdout: list of links
#
# Notes:
# - multiupload.com direct link is not printed
# - empty folder (return $ERR_LINK_DEAD) is not possible
multiupload_list() {
    eval "$(process_options multiupload "$MODULE_MULTIUPLOAD_LIST_OPTIONS" "$@")"

    local URL="$1"
    local PAGE LINKS

    PAGE=$(curl "$URL" | break_html_lines_alt) || return
    LINKS=$(echo "$PAGE" | parse_all_attr '"urlhref' 'href')

    test "$2" && log_debug "recursive flag has no sense with this module"

    if test -z "$LINKS"; then
        log_error "Wrong directory list link"
        return $ERR_FATAL
    fi

    while read LINE; do
        curl -I "$LINE" | grep_http_header_location
    done <<< "$LINKS"
}
