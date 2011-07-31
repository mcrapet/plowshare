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
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3 (optional): alternate remote filename
# stdout: multiupload.com download link
#
# Note: No external premium account (RS, MU, ...) support.
multiupload_upload() {
    eval "$(process_options multiupload "$MODULE_MULTIUPLOAD_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local FILE="$2"
    local DESTFILE=${3:-$FILE}
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

    # keep default settings
    local form_site1=$(echo "$form" | parse_form_input_by_name 'service_5')
    local form_site2=$(echo "$form" | parse_form_input_by_name 'service_1')
    local form_site3=$(echo "$form" | parse_form_input_by_name 'service_7')
    local form_site4=$(echo "$form" | parse_form_input_by_name 'service_9')
    local form_site5=$(echo "$form" | parse_form_input_by_name 'service_6')
    local form_site6=$(echo "$form" | parse_form_input_by_name 'service_10')
    local form_site7=$(echo "$form" | parse_form_input_by_name 'service_15')
    local form_site8=$(echo "$form" | parse_form_input_by_name 'service_14')

    test "$NO_UPLOADING_COM" && form_site6=''

    # Notes:
    # - file0 can go to file9 (included)
    # - fetchfield0 & fetchdesc0 are not used here
    # - there is a special variable "rsaccount" for RS (can be "C" or "P")
    # - hosters: RS, MU, DF, HF, ZS, UP, FC, FS
    PAGE=$(curl_with_log -0 -b "$COOKIEFILE" \
        -F "file0=@$FILE;filename=$(basename_file "$DESTFILE")" \
        -F "description_0=$DESCRIPTION" \
        -F "X-Progress-ID=$form_x" \
        -F "u=$form_u" \
        -F "service_5=$form_site1"  -F "username_5="  -F "password_5="  -F "remember_5="  \
        -F "service_1=$form_site2"  -F "username_1="  -F "password_1="  -F "remember_1="  \
        -F "service_7=$form_site3"  -F "username_7="  -F "password_7="  -F "remember_7="  \
        -F "service_9=$form_site4"  -F "username_9="  -F "password_9="  -F "remember_9="  \
        -F "service_6=$form_site5"  -F "username_6="  -F "password_6="  -F "remember_6="  \
        -F "service_10=$form_site6" -F "username_10=" -F "password_10=" -F "remember_10=" \
        -F "service_15=$form_site7" -F "username_15=" -F "password_15=" -F "remember_15=" \
        -F "service_14=$form_site8" -F "username_14=" -F "password_14=" -F "remember_14=" \
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
        { log_error "Wrong directory list link"; return 1; }

    if test -z "$LINKS"; then
        log_error "This is not a directory list"
        return 1
    fi

    while read LINE; do
        curl -I "$LINE" | grep_http_header_location
    done <<< "$LINKS"
}
