#!/bin/bash
#
# mirrorcreator.com module
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

MODULE_MIRRORCREATOR_REGEXP_URL="http://\(www\.\)\?\(mirrorcreator\.com\|mir\.cr\)/"

MODULE_MIRRORCREATOR_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
INCLUDE,,include,l=LIST,Provide list of host site (space separated)
COUNT,,count,n=COUNT,Take COUNT hosters from the available list. Default is 5."
MODULE_MIRRORCREATOR_UPLOAD_REMOTE_SUPPORT=no

MODULE_MIRRORCREATOR_LIST_OPTIONS=""

# Upload a file to mirrorcreator.com
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: mirrorcreator.com download link
mirrorcreator_upload() {
    local COOKIEFILE=$1
    local FILE=$2
    local DESTFILE=$3
    local SZ=$(get_filesize "$FILE")
    local BASE_URL='http://www.mirrorcreator.com'
    local PAGE FORM SITES_SEL SITES_ALL SITE DATA

    # File size limit check (warning message only)
    if [ "$SZ" -gt 419430400 ]; then
        log_debug "file is bigger than 400MB, some site may not support it"
    fi

    if [ -n "$AUTH_FREE" ]; then
        local LOGIN_DATA LOGIN_RESULT

        LOGIN_DATA='username=$USER&password=$PASSWORD'
        LOGIN_RESULT=$(post_login "$AUTH_FREE" "$COOKIEFILE" "$LOGIN_DATA" \
            "$BASE_URL/members/login_.php" \
            -H 'X-Requested-With: XMLHttpRequest') || return

        if [ "$LOGIN_RESULT" -eq 0 ]; then
            return $ERR_LOGIN_FAILED
        fi

        # get PHPSESSID entry in cookie file
    fi

    PAGE=$(curl "$BASE_URL") || return
    FORM=$(grep_form_by_id "$PAGE" 'uu_upload' | break_html_lines)

    # Retrieve complete hosting site list
    SITES_ALL=$(echo "$FORM" | grep 'checkbox' | parse_all_attr 'id=' value)

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

        if [ "$COUNT" -gt 9 ]; then
            log_error "Only a maximum of 9 mirrors are allowed"
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
        SITES_SEL=$(echo "$FORM" | parse_all_attr 'checked=' 'value')
    fi

    if [ -z "$SITES_SEL" ]; then
        log_debug "Empty site selection. Nowhere to upload!"
        return $ERR_FATAL
    fi

    log_debug "Selected sites:" $SITES_SEL

    # Do not seem needed..
    #PAGE=$(curl "$BASE_URL/fnvalidator.php?fn=${DESTFILE};&fid=upfile_123;")

    # -b "$COOKIEFILE" not needed here
    PAGE=$(curl_with_log \
        --user-agent "Shockwave Flash" \
        -F "Filename=$DESTFILE" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        -F 'folder=/uploads' -F 'Upload=Submit Query' \
        "$BASE_URL/uploadify/uploadify.php") || return

    # Filename can be renamed if "slot" already taken!
    # {"fileName": "RFC-all.tar.gz"}
    DESTFILE=$(echo "$PAGE" | parse 'fileName' ':[[:space:]]*"\([^"]\+\)"')
    log_debug "filename=$DESTFILE"

    # Some basic base64 encoding:
    # > FilesNames +=value + '#0#' + filesCompletedSize[key]+ ';0;';
    # > submitData = filesNames + '@e@' + email + '#H#' + selectedHost +'#P#' + pass + '#SC#' + scanvirus;
    # Example: RFC-all.tar.gz#0#225280;0;@e@#H#turbobit;hotfile;#P#
    DATA=$(echo "$SITES_SEL" | replace ' ' ';' | replace $'\n' ';')

    log_debug "sites=$DATA"
    DATA=$(echo "${DESTFILE}#0#${SZ};0;@e@#H#${DATA};#P#${LINK_PASSWORD}#SC#" | base64 --wrap=0)
    PAGE=$(curl -b "$COOKIEFILE" --referer "$BASE_URL" \
        "$BASE_URL/process.php?data=$DATA") || return

    echo "$PAGE" | parse_attr 'getElementById("link2")' 'href' || return
    return 0
}

# List links from a mirrorcreator link
# $1: mirrorcreator link
# $2: recurse subfolders (ignored here)
# stdout: list of links
mirrorcreator_list() {
    local URL=$1
    local PAGE STATUS LINKS NAMES REL_URL
    local BASE_URL='http://www.mirrorcreator.com'

    if test "$2"; then
        log_error "Recursive flag has no sense here, abort"
        return $ERR_BAD_COMMAND_LINE
    fi

    PAGE=$(curl -L "$URL") || return
    STATUS=$(echo "$PAGE" | parse 'status\.php' ',[[:space:]]"\([^"]*\)",') || return
    PAGE=$(curl -L "$BASE_URL$STATUS") || return

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet '/redirect/' href) || return
    if [ -z "$LINKS" ]; then
        return $ERR_LINK_DEAD
    fi

    NAMES=( $(echo "$PAGE" | parse_all '/redirect/' '\.gif"[[:space:]]alt="\([^"]*\)') )

    while read REL_URL; do
        test "$REL_URL" || continue
        URL=$(curl "$BASE_URL$REL_URL" | parse_tag 'redirecturl' div) || return

        echo "$URL"
        echo "${NAMES[0]}"

        # Drop first element
        NAMES=("${NAMES[@]:1}")
    done <<< "$LINKS"
}
