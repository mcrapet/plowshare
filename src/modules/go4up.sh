# Plowshare go4up.com module
# Copyright (c) 2012-2013 Plowshare team
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

MODULE_GO4UP_REGEXP_URL='http://\(www\.\)\?go4up\.com'

MODULE_GO4UP_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account
INCLUDE,,include,l=LIST,Provide list of host site (comma separated)
COUNT,,count,n=COUNT,Take COUNT mirrors (hosters) from the available list. Default is 5.
API,,api,,Use public API (recommended)"
MODULE_GO4UP_UPLOAD_REMOTE_SUPPORT=yes

MODULE_GO4UP_DELETE_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"

MODULE_GO4UP_LIST_OPTIONS=""
MODULE_GO4UP_LIST_HAS_SUBFOLDERS=no

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
go4up_login() {
    local AUTH_FREE=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3
    local LOGIN_DATA PAGE NAME

    LOGIN_DATA='email=$USER&password=$PASSWORD&signin_go='
    PAGE=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
       "$BASE_URL/login.php" -b "$COOKIE_FILE") || return

    if match 'Bad email/password.' "$PAGE" || \
        match 'Please enter a valid email address' "$PAGE"; then
        return $ERR_LOGIN_FAILED
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/account.php")

    # The new password will be confirmed at : <b>USER_MAIL</b>
    NAME=$(echo "$PAGE" | parse_tag \
        'The new password will be confirmed at' b) || return

    log_debug "Successfully logged in as member '$NAME'"
}

# Upload a file to go4up.com
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: go4up.com download link
go4up_upload() {
    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://go4up.com'
    local PAGE LINK FORM UPLOAD_ID USER_ID UPLOAD_BASE_URL
    local SITE HOST SITES_ALL SITES_SEL SITES_FORM SITES_MULTI

    if [ -n "$API" ]; then
        log_debug 'using public API'

        # Check if API can handle this upload
        if [ -z "$AUTH_FREE" ]; then
            log_error 'Public API is only available for registered users.'
            return $ERR_BAD_COMMAND_LINE
        fi

        if [ -n "$COUNT" -o "${#INCLUDE[@]}" -gt 0 ]; then
            log_error 'Public API does not support hoster selection.'
            return $ERR_BAD_COMMAND_LINE
        fi

        if match_remote_url "$FILE"; then
            log_error 'Public API does not support remote upload.'
            return $ERR_BAD_COMMAND_LINE
        fi

        local USER PASSWORD
        split_auth "$AUTH_FREE" USER PASSWORD || return

        # http://go4up.com/wiki/index.php/API_doc
        PAGE=$(curl -F "user=$USER" -F "pass=$PASSWORD" \
            -F "filedata=@$FILE" "$BASE_URL/api/upload.php")

        if match '<link>' "$PAGE"; then
            : # Nothing to do, just catch the "good" case
        elif match '>Invalid login/password<' "$PAGE"; then
            return $ERR_LOGIN_FAILED
        # Invalid post data count
        # Choose host to upload in your account
        else
            local ERR=$(echo "$PAGE" | parse_tag error)
            log_error "Remote error: $ERR"
            return $ERR_FATAL
        fi

        echo "$PAGE" | parse_tag 'link'
        return 0
    fi

    # Public API not used

    # Login needs to go before retrieving hosters because accounts
    # have a individual hoster lists
    if [ -n "$AUTH_FREE" ]; then
        go4up_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    # Retrieve complete hosting site list
    # Note: This can be either our first contact with Go4Up (no login)
    #       or the second (with login), so we need both -b and -c.
    if match_remote_url "$FILE"; then
        PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
            "$BASE_URL/remote.php") || return
        FORM=$(grep_form_by_id "$PAGE" 'form_upload' | break_html_lines) || return
        UPLOAD_BASE_URL=$(echo "$FORM" | parse_form_action) || return
    else
        PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
            "$BASE_URL") || return
        UPLOAD_BASE_URL=$(echo "$PAGE" | parse_attr iframe src) || return
        PAGE=$(curl "$UPLOAD_BASE_URL") || return
        FORM=$(grep_form_by_id "$PAGE" 'ubr_upload_form' | break_html_lines) || return
    fi

    UPLOAD_BASE_URL=$(basename_url "$UPLOAD_BASE_URL") || return
    log_debug "Upload base URL: $UPLOAD_BASE_URL"

    # When logged into account all form fields are on a single line
    if [ -n "$AUTH_FREE" ]; then
        FORM=$(echo "$FORM" | break_html_lines)
    fi

    USER_ID=$(echo "$FORM" | parse_form_input_by_name_quiet 'id_user')
    SITES_ALL=$(echo "$FORM" | parse_all_attr checkbox value) || return

    # Code copied from mirrorcreator module
    if [ -z "$SITES_ALL" ]; then
        log_error 'Empty list, site updated?'
        return $ERR_FATAL
    fi

    log_debug "Available sites:" $SITES_ALL

    if [ -n "$COUNT" ]; then
        #if (( COUNT > 10 )); then
        #    COUNT=10
        #    log_error "Too big integer value for --count, set it to $COUNT"
        #fi

        for SITE in $SITES_ALL; do
            (( COUNT-- > 0 )) || break
            SITES_SEL="$SITES_SEL $SITE"
        done
    elif [ "${#INCLUDE[@]}" -gt 0 ]; then
        for SITE in "${INCLUDE[@]}"; do
            # FIXME: Should match word boundary (\< & \> are GNU grep extensions)
            if match "$SITE" "$SITES_ALL"; then
                SITES_SEL="$SITES_SEL $SITE"
            else
                log_error "Host not supported: $SITE, ignoring"
            fi
        done
    else
        # Default hosting sites selection
        SITES_SEL=$(echo "$FORM" | parse_all_attr checked value) || return
    fi

    if [ -z "$SITES_SEL" ]; then
        log_debug 'Empty site selection. Nowhere to upload!'
        return $ERR_FATAL
    fi
    # End of code copy

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

        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -F "APC_UPLOAD_PROGRESS=$UPLOAD_ID" \
            -F "id_user=$USER_ID" \
            -F "url=$FILE" \
            $SITES_MULTI \
            "$UPLOAD_BASE_URL/copy_remote.php") || return

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
            $SITES_FORM \
            -d "id_user=$USER_ID" \
            -d "upload_file[]=$DESTFILE" \
            "$UPLOAD_BASE_URL$UPLOAD_URL1") || return

        # if(typeof UberUpload.startUpload == 'function')
        # { UberUpload.startUpload("f7c3511c7eac0716dc64bba7e32ef063",0,0); }
        UPLOAD_ID=$(echo "$PAGE" | parse 'startUpload(' '"\([^"]\+\)"') || return
        log_debug "Upload ID: $UPLOAD_ID"

        # Note: No need to call ubr_set_progress.php, ubr_get_progress.php

        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -F "id_user=$USER_ID" \
            -F "upfile_$(date +%s)000=@$FILE;filename=$DESTFILE" \
            $SITES_MULTI \
            "$UPLOAD_BASE_URL$UPLOAD_URL2?upload_id=$UPLOAD_ID") || return

        # parent.UberUpload.redirectAfterUpload('../../uploaded.php?upload_id=9f07...
        UPLOAD_URL1=$(echo "$PAGE" | \
            parse 'redirectAfter' "('\([^']\+\)'") || return

        PAGE=$(curl -b "$COOKIE_FILE" "$UPLOAD_URL1") || return

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
    local PAGE LINKS NAME SITE_URL

    PAGE=$(curl -L "$URL" | break_html_lines) || return

    if match 'The file is being uploaded on mirror websites' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'does not exist or has been removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'class="dl"' href) || return
    if [ -z "$LINKS" ]; then
        log_error 'No links found. Site updated?'
        return $ERR_FATAL
    fi

    while read SITE_URL; do
        [[ "$SITE_URL" = */premium ]] && continue

        PAGE=$(curl --include "$SITE_URL") || return
        URL=$(grep_http_header_location_quiet <<< "$PAGE")

        # window.location = "http://... " <= extra space at the end
        if [ -z "$URL" ]; then
            URL=$(echo "$PAGE" | parse_quiet 'window\.location' '=[[:space:]]*"\([^"]*\)')
            URL=${URL% }

            # <meta http-equiv="REFRESH" content="0;url=http://..."></HEAD>
            if [ -z "$URL" ]; then
                URL=$(echo "$PAGE" | parse_quiet 'http-equiv' 'url=\([^">]\+\)')
                if [ -z "$URL" ]; then
                    log_debug "remote error: link error? Ingore $SITE_URL"
                    continue
                fi
            fi
        fi

        NAME=$(echo "$SITE_URL" | parse . '/\(.*\)$')

        echo "$URL"
        echo "$NAME"
    done <<< "$LINKS"
}

# Delete a file on go4up.com
# $1: cookie file
# $2: file URL
go4up_delete() {
    local COOKIE_FILE=$1
    local URL=$2
    local BASE_URL='http://go4up.com'
    local PAGE FILE_ID

    test "$AUTH_FREE" || return $ERR_LINK_NEED_PERMISSIONS

    # Parse URL
    # http://go4up.com/link.php?id=1Ddupi2qxbwl
    # http://go4up.com/dl/1Ddupi2qxbwl
    FILE_ID=$(echo "$URL" | parse . '[=/]\([[:alnum:]]\+\)$') || return
    log_debug "File ID: $FILE_ID"

    # Check link
    PAGE=$(curl "$URL") || return
    match 'does not exist or has been removed' "$PAGE" && \
        return $ERR_LINK_DEAD

    go4up_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    PAGE=$(curl -b "$COOKIE_FILE" -d "id=$FILE_ID" \
        "$BASE_URL/delete.php") || return

    # Note: Go4up will *always* send this reply
    match 'Your link has been deleted from our database' "$PAGE" || \
        return $ERR_FATAL

    # Check if link is really gone
    PAGE=$(curl "$URL") || return
    if ! match 'does not exist or has been removed' "$PAGE"; then
        log_error 'File NOT removed. Correct account?'
        return $ERR_LINK_NEED_PERMISSIONS
    fi
}
