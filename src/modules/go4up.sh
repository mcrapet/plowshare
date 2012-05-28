#!/bin/bash
#
# go4up.com module
# Copyright (c) 2012 Plowshare team
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

MODULE_GO4UP_REGEXP_URL="http://\(www\.\)\?go4up\.com"

MODULE_GO4UP_UPLOAD_OPTIONS="
INCLUDE,,include:,LIST,Provide list of host site (space separated)
COUNT,,count:,COUNT,Take COUNT hosters from the available list. Default is 5."
MODULE_GO4UP_UPLOAD_REMOTE_SUPPORT=yes

MODULE_GO4UP_LIST_OPTIONS=""

# Upload a file to go4up.com
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: go4up.com download link
go4up_upload() {
    eval "$(process_options go4up "$MODULE_GO4UP_UPLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://go4up.com'
    local PAGE LINK FORM UPLOAD_ID
    local SITES_ALL SITES_SEL SITES_FORM SITES_MULTI

    # Registered users can use public API:
    # http://go4up.com/wiki/index.php/API_doc

    # Retrieve complete hosting site list
    if match_remote_url "$FILE"; then
        PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL/remote.php") || return

        FORM=$(grep_form_by_id "$PAGE" 'form_upload') || return
    else
        PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL") || return

        FORM=$(grep_form_by_id "$PAGE" 'ubr_upload_form') || return
    fi

    SITES_ALL=$(echo "$FORM" | parse_all_attr 'type="checkbox"' value)

    # Code copied from mirrorcreator module
    if [ -z "$SITES_ALL" ]; then
        log_error "Empty list, site updated?"
        return $ERR_FATAL
    else
        log_debug "Available sites:" $SITES_ALL
    fi

    if [ -n "$COUNT" ]; then
        if [[ $((COUNT)) -eq 0 ]]; then
            COUNT=5
            log_error "Bad integer value for --count, set it to $COUNT"
        fi

        for SITE in $SITES_ALL; do
            (( COUNT-- > 0 )) || break
            SITES_SEL="$SITES_SEL $SITE"
        done
    elif [ -n "$INCLUDE" ]; then
        for SITE in $INCLUDE; do
            if match "$SITE" "$SITES_ALL"; then
                SITES_SEL="$SITES_SEL $SITE"
            else
                log_error "Host not supported: $SITE, ignoring"
            fi
        done
    else
        # Default hosting sites selection
        SITES_SEL=$(echo "$FORM" | \
            parse_all_attr 'type="checkbox".*checked' 'value')
    fi

    if [ -z "$SITES_SEL" ]; then
        log_debug "Empty site selection. Nowhere to upload!"
        return $ERR_FATAL
    fi

    # Prepare lists of hosts to mirror to
    for HOST in $SITES_SEL; do
        log_debug "selected site: $HOST"
        SITES_FORM="$SITES_FORM -d box%5B%5D=$HOST"
        SITES_MULTI="$SITES_MULTI -F box[]=$HOST"
    done

    # Proceed with upload
    if match_remote_url "$FILE"; then
        if [ "$DESTFILE" != 'dummy' ]; then
            log_error 'Remote filename ignored, not supported by site'
        fi

        UPLOAD_ID=$(echo "$FORM" | \
            parse_form_input_by_id 'progress_key') || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            --referer "$BASE_URL/remote.php" \
            -F "APC_UPLOAD_PROGRESS=$UPLOAD_ID" \
            -F 'id_user=0' \
            -F "url=$FILE" \
            $SITES_MULTI \
            "$BASE_URL/copy_remote.php") || return

        if ! match 'Your link' "$PAGE"; then
            log_error 'Error uploading to server'
            return $ERR_FATAL
        fi
        LINK="http://www.go4up.com/dl/$UPLOAD_ID"
    else
        local UPLOAD_URL1 UPLOAD_URL2

        # Site uses UberUpload for direct upload
        UPLOAD_URL1=$(echo "$PAGE" | \
            parse 'path_to_link_script' '"\([^"]\+\)"') || return
        UPLOAD_URL2=$(echo "$PAGE" | \
            parse 'path_to_upload_script' '"\([^"]\+\)"') || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            --referer "$BASE_URL/index.php" \
            $SITES_FORM \
            -d 'id_user=0' \
            -d "upload_file[]=$DESTFILE" \
            "$BASE_URL$UPLOAD_URL1") || return

        # if(typeof UberUpload.startUpload == 'function')
        # { UberUpload.startUpload("f7c3511c7eac0716dc64bba7e32ef063",0,0); }
        UPLOAD_ID=$(echo "$PAGE" | parse 'startUpload(' '"\([^"]\+\)"') || return
        log_debug "id: $UPLOAD_ID"

        # Note: No need to call ubr_set_progress.php, ubr_get_progress.php

        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            --referer "$BASE_URL/index.php" \
            -F 'id_user=0' \
            -F "upfile_$(date +%s)000=@$FILE;filename=$DESTFILE" \
            $SITES_MULTI \
            "$BASE_URL$UPLOAD_URL2?upload_id=$UPLOAD_ID") || return

        # parent.UberUpload.redirectAfterUpload('../../uploaded.php?upload_id=9f07...
        UPLOAD_URL1=$(echo "$PAGE" | \
            parse 'redirectAfter' "'\.\./\.\.\([^']\+\)'") || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            --referer "$BASE_URL/index.php" \
            "$BASE_URL$UPLOAD_URL1") || return

        LINK=$(echo "$PAGE" | parse_attr '/dl/' href) || return
    fi

    echo "$LINK"
}

# List links from a go4up link
# $1: go4up link
# $2: recurse subfolders (ignored here)
# stdout: list of links
go4up_list() {
    local URL=$1
    local PAGE LINKS SITE_URL

    test "$2" && log_debug "recursive flag specified but has no sense here, ignore it"

    PAGE=$(curl -L "$URL") || return

    if match 'The file is being uploaded on mirror websites' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'does not exist or has been removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    LINKS=$(echo "$PAGE" | parse_all_tag_quiet 'class="dl"' a) || return
    if [ -z "$LINKS" ]; then
        log_error 'No links found. Site updated?'
        return $ERR_FATAL
    fi

    #  Print links (stdout)
    while read SITE_URL; do
        test "$SITE_URL" || continue

        # <meta http-equiv="REFRESH" content="0;url=http://..."></HEAD>
        PAGE=$(curl "$SITE_URL") || return
        echo "$PAGE" | parse 'http-equiv' 'url=\([^">]\+\)'
    done <<< "$LINKS"
}
