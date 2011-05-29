#!/bin/bash
#
# mirrorcreator.com module
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

MODULE_MIRRORCREATOR_REGEXP_URL="http://\(www\.\)\?\(mirrorcreator\.com\|mir\.cr\)/"
MODULE_MIRRORCREATOR_UPLOAD_OPTIONS=""

# $1: input file
# $2 (optional): alternate destination filename
# stdout: mirrorcreator.com upload link
mirrorcreator_upload() {
    eval "$(process_options mirrorcreator "$MODULE_MIRRORCREATOR_UPLOAD_OPTIONS" "$@")"

    local FILE=$1
    local DESTFILE=${2:-$FILE}
    local BASE_URL="http://www.mirrorcreator.com"

    PAGE=$(curl "$BASE_URL")

    local FORM=$(grep_form_by_id "$PAGE" 'uu_upload')

    HOSTERS=$(echo "$FORM" | parse_all 'checked' '">\([^<]*\)<br')
    N=0
    if [ -n "$HOSTERS" ]; then
        log_debug "Hosting sites:"
        while read H; do
            log_debug "- $H"
            (( N++ ))
        done <<< "$HOSTERS"
    fi

    # Retrieve complete hosters list
    local SITES=$(echo "$FORM" | parse_all_form_input_by_type_with_id 'checkbox')

    if [ -z "$SITES" ]; then
        log_error "Empty list, site updated?"
        return 1
    fi

    # Do not seem needed..
    #PAGE=$(curl "$BASE_URL/fnvalidator.php?fn=$(basename_file "$DESTFILE");&fid=upfile_123;")

    # Set N to a bigger value to upload to more hosters
    CURL_STRING=''
    while read H; do
        (( N-- <= 0 )) && break;
        CURL_STRING+=" -F ${H}=on"
    done <<< "$SITES"

    # Site is using third part uploader compoment: Uper-Uploader
    # (http://uber-uploader.sourceforge.net/)
    # Remark: Calling "uber/ubr_set_progress.php" and "uber/ubr_get_progress.php"
    # is not required here.

    ID=$(curl "$BASE_URL/uber/ubr_link_upload.php?_=1306654898605" | parse_quiet 'startUpload' '("\([^"]*\)')
    log_debug "Upload ID: $ID"

    PAGE=$(curl_with_log -L \
        -F "upfile_123=@$FILE;filename=$(basename_file "$DESTFILE")" -F "mail=" \
        $CURL_STRING \
        "$BASE_URL/cgi-bin/ubr_upload.pl?upload_id=$ID") ||
        { log_error "Couldn't upload file!"; return 1; }

    # Custom version of "uber/ubr_finished.php"
    PAGE=$(curl "$BASE_URL/process.php?upload_id=$ID") ||
        { log_error "Can't get results"; return 1; }

    echo "$PAGE" | parse_attr 'getElementById("link2")' 'href'
    return 0
}

