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
HOTFILE,,hotfile,,Include this additional host site
MEDIAFIRE,,mediafire,,Include this additional host site
RAPIDSHARE,,rapidshare,,Include this additional host site
ZSHARE,,zshare,,Include this additional host site"
MODULE_MIRRORCREATOR_UPLOAD_REMOTE_SUPPORT=no

# Upload a file to mirrorcreator.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: mirrorcreator.com download link
mirrorcreator_upload() {
    eval "$(process_options mirrorcreator "$MODULE_MIRRORCREATOR_UPLOAD_OPTIONS" "$@")"

    local FILE=$2
    local DESTFILE=$3
    local SZ=$(get_filesize "$FILE")
    local BASE_URL='http://www.mirrorcreator.com'
    local PAGE FORM SITES_SEL SITES_ALL DATA

    # Warning message
    if [ "$SZ" -gt 419430400 ]; then
        log_error "warning: file is bigger than 400MB, some site may not support it"
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

    # Default hosting sites selection
    SITES_SEL=$(echo "$FORM" | parse_all_attr 'checked=' 'value')

    # Check command line additionnal hosters
    [ -n "$HOTFILE" ]    && SITES_SEL="$SITES_SEL hotfile"
    [ -n "$MEDIAFIRE" ]  && SITES_SEL="$SITES_SEL mediafire"
    [ -n "$RAPIDSHARE" ] && SITES_SEL="$SITES_SEL rapidshare"
    [ -n "$ZSHARE" ]     && SITES_SEL="$SITES_SEL zshare"

    if [ -n "$SITES_SEL" ]; then
        log_debug "Selected sites:" $SITES_SEL
    fi

    # Do not seem needed.. (account stuff?)
    #PAGE=$(curl "$BASE_URL/fnvalidator.php?fn=${DESTFILE};&fid=upfile_123;")

    PAGE=$(curl_with_log "$BASE_URL/uploadify/uploadify.php" \
        --user-agent "Shockwave Flash" \
        -F "Filename=$DESTFILE" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        -F 'folder=/uploads' -F 'Upload=Submit Query')

    # Filename can be renamed if "slot" already taken!
    # {"fileName": "RFC-all.tar.gz"}
    DESTFILE=$(echo "$PAGE" | parse 'fileName' ':[[:space:]]*"\([^"]\+\)"')
    log_debug "filename=$DESTFILE"

    # Some basic base64 encoding:
    # > FilesNames +=value + '#0#' + filesCompletedSize[key]+ ';0;';
    # > submitData = filesNames + '@e@' + email + '#H#' + selectedHost +'#P#' + pass;
    # Example: RFC-all.tar.gz#0#225280;0;@e@#H#zshare;wupload;#P#
    DATA=$(echo "$SITES_SEL" | replace ' ' ';' | tr '\n' ';')

##
# FIXME: something is wrong, only the 2 first entries are taken of my list.
##

    log_debug "sites=$DATA"
    DATA=$(echo "${DESTFILE}#0#${SZ};0;@e@#H#${DATA}#P#" | base64)
    PAGE=$(curl --referer "$BASE_URL" \
        "$BASE_URL/process.php?data=$DATA") || return


    echo "$PAGE" | parse_attr 'getElementById("link2")' 'href' || return
    return 0
}
