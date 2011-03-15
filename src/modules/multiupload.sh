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
DESCRIPTION,d:,description:,DESCRIPTION,Set file description"
MODULE_MULTIUPLOAD_LIST_OPTIONS=""

# $1: input file
# $2 (optional): alternate destination filename
# stdout: multiupload.com upload link
#
# No external premium account (RS, MU, ...) support.
multiupload_upload() {
    eval "$(process_options multiupload "$MODULE_MULTIUPLOAD_UPLOAD_OPTIONS" "$@")"

    local FILE=$1
    local DESTFILE=${2:-$FILE}
    local BASE_URL="http://www.multiupload.com"

    PAGE=$(curl "$BASE_URL" | break_html_lines_alt)

    local form=$(grep_form_by_id "$PAGE" uploadfrm)
    local form_action=$(echo "$form" | parse_form_action)
    local form_uid=$(echo "$form" | parse_form_input_by_name 'UPLOAD_IDENTIFIER')
    local form_u=$(echo "$form" |  parse_form_input_by_name 'u')

    log_debug "Upload ID: $form_uid / $form_u"

    # keep default settings
    local form_site1=$(echo "$form" | parse_form_input_by_name 'service_5')
    local form_site2=$(echo "$form" | parse_form_input_by_name 'service_1')
    local form_site3=$(echo "$form" | parse_form_input_by_name 'service_7')
    local form_site4=$(echo "$form" | parse_form_input_by_name 'service_9')
    local form_site5=$(echo "$form" | parse_form_input_by_name 'service_6')
    local form_site6=$(echo "$form" | parse_form_input_by_name 'service_10')

    # Notes:
    # - file0 can go to file9 (included)
    # - fetchfield0 & fetchdesc0 are not used here
    # - there is a special variable "rsaccount" for RS (can be "C" or "P")

    PAGE2=$(curl_with_log \
        -F "file0=@$FILE;filename=$(basename_file "$DESTFILE")" \
        -F "description_0=$DESCRIPTION" \
        -F "UPLOAD_IDENTIFIER=$form_uid" \
        -F "u=$form_u" \
        -F "service_5=$form_site1"  -F "username_5="  -F "password_5="  -F "remember_5="  \
        -F "service_1=$form_site2"  -F "username_1="  -F "password_1="  -F "remember_1="  \
        -F "service_7=$form_site3"  -F "username_7="  -F "password_7="  -F "remember_7="  \
        -F "service_9=$form_site4"  -F "username_9="  -F "password_9="  -F "remember_9="  \
        -F "service_6=$form_site5"  -F "username_6="  -F "password_6="  -F "remember_6="  \
        -F "service_10=$form_site6" -F "username_10=" -F "password_10=" -F "remember_10=" \
        $form_action) ||
        { log_error "Couldn't upload file!"; return 1; }

    DLID=$(echo "$PAGE2" | parse_quiet 'downloadid' 'downloadid":"\([^"]*\)')
    log_debug "Download ID: $DLID"

    if [ -z "$DLID" ]; then
        log_error "Unepected result (site updated?)"
        return 1
    fi

    echo "$BASE_URL/$DLID"
}

# List multiple hosting site links
# $1: multiupload.com link
# stdout: list of links
multiupload_list() {
    eval "$(process_options multiupload "$MODULE_MULTIUPLOAD_LIST_OPTIONS" "$@")"
    URL=$1

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
