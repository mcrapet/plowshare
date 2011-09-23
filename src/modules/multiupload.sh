#!/bin/bash
#
# multiupload.com module
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

MODULE_MULTIUPLOAD_REGEXP_URL="http://\(www\.\)\?multiupload\.com/"

MODULE_MULTIUPLOAD_UPLOAD_OPTIONS="
DESCRIPTION,d:,description:,DESCRIPTION,Set file description
AUTH,a:,auth:,USER:PASSWORD,User account
FROMEMAIL,,email-from:,EMAIL,<From> field for notification email
TOEMAIL,,email-to:,EMAIL,<To> field for notification email
NO_UPLOADING_COM,,no-up,,Exclude Uploading.com from host list"
MODULE_MULTIUPLOAD_LIST_OPTIONS=""

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
    local BASE_URL="http://www.multiupload.com"

    if test "$AUTH"; then
        local USER PASSWORD LOGIN_RESULT

        USER="${AUTH%%:*}"
        PASSWORD="${AUTH#*:}"

        if [ "$AUTH" = "$PASSWORD" ]; then
            PASSWORD=$(prompt_for_password) || return $ERR_LOGIN_FAILED
        fi

        LOGIN_RESULT=$(curl -L -c "$COOKIEFILE" -F "username=$USER" \
                -F "password=$PASSWORD" "$BASE_URL/login") || return

        if ! match 'Logged in' "$LOGIN_RESULT"; then
            return $ERR_LOGIN_FAILED
        fi
    fi

    local PAGE=$(curl -b "$COOKIEFILE" "$BASE_URL" | break_html_lines_alt)

    local form=$(grep_form_by_id "$PAGE" uploadfrm)
    local form_action=$(echo "$form" | parse_form_action)
    local form_u=$(echo "$form" | parse_form_input_by_name 'u')
    local form_x=$(echo "$form" | parse_form_input_by_name 'X-Progress-ID')

    log_debug "Upload ID: $form_u / ${form_x:-No Progress-ID}"

    # Hosters list
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

    # Hosters (2011.09.12): MU, UK, DF, UH, HF, UP
    # Keep default settings
    local form_site1=$(echo "$form" | parse_form_input_by_name 'service_1')
    local form_site2=$(echo "$form" | parse_form_input_by_name 'service_16')
    local form_site3=$(echo "$form" | parse_form_input_by_name 'service_7')
    local form_site4=$(echo "$form" | parse_form_input_by_name 'service_17')
    local form_site5=$(echo "$form" | parse_form_input_by_name 'service_9')
    local form_site6=$(echo "$form" | parse_form_input_by_name 'service_10')

    test "$NO_UPLOADING_COM" && form_site6=''

    # Notes:
    # - file0 can go to file9 (included)
    # - fetchfield0 & fetchdesc0 are not used here
    # - there is a special variable "rsaccount" for RS (can be "C" or "P")
    PAGE=$(curl_with_log -0 -b "$COOKIEFILE" \
        -F "file0=@$FILE;filename=$DESTFILE" \
        -F "description_0=$DESCRIPTION" \
        -F "X-Progress-ID=$form_x" \
        -F "u=$form_u" \
        -F "service_1=$form_site1"  -F "username_1="  -F "password_1="  -F "remember_1="  \
        -F "service_16=$form_site2" -F "username_16=" -F "password_16=" -F "remember_16=" \
        -F "service_7=$form_site3"  -F "username_7="  -F "password_7="  -F "remember_7="  \
        -F "service_17=$form_site4" -F "username_17=" -F "password_17=" -F "remember_17=" \
        -F "service_9=$form_site5"  -F "username_9="  -F "password_9="  -F "remember_9="  \
        -F "service_10=$form_site6" -F "username_10=" -F "password_10=" -F "remember_10=" \
        -F "fromemail=$FROMEMAIL" -F "toemail=$TOEMAIL" $form_action) || return

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
# stdout: list of links
multiupload_list() {
    eval "$(process_options multiupload "$MODULE_MULTIUPLOAD_LIST_OPTIONS" "$@")"

    local URL="$1"

    LINKS=$(curl "$URL" | break_html_lines_alt | parse_all_attr '"urlhref' 'href') || \
        { log_error "Wrong directory list link"; return $ERR_FATAL; }

    if test -z "$LINKS"; then
        log_error "This is not a directory list"
        return $ERR_FATAL
    fi

    while read LINE; do
        curl -I "$LINE" | grep_http_header_location
    done <<< "$LINKS"
}
