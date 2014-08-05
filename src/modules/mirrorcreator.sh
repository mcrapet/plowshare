# Plowshare mirrorcreator.com module
# Copyright (c) 2011-2014 Plowshare team
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

MODULE_MIRRORCREATOR_REGEXP_URL='https\?://\(www\.\)\?\(mirrorcreator\.com\|mir\.cr\)/'

MODULE_MIRRORCREATOR_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
INCLUDE,,include,l=LIST,Provide list of host site (comma separated)
SECURE,,secure,,Use HTTPS site version
FULL_LINK,,full-link,,Final link includes filename
COUNT,,count,n=COUNT,Take COUNT mirrors (hosters) from the available list. Default is 3, maximum is 12."
MODULE_MIRRORCREATOR_UPLOAD_REMOTE_SUPPORT=no

MODULE_MIRRORCREATOR_LIST_OPTIONS=""
MODULE_MIRRORCREATOR_LIST_HAS_SUBFOLDERS=no

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
    if [ -n "$SECURE" ]; then
        local BASE_URL='https://www.mirrorcreator.com'
    else
        local BASE_URL='http://www.mirrorcreator.com'
    fi
    local PAGE FORM SITES_SEL SITES_ALL SITE DATA

    if ! check_exec 'base64'; then
        log_error "'base64' is required but was not found in path."
        return $ERR_SYSTEM
    fi

    # File size limit check (warning message only)
    if [ "$SZ" -gt 419430400 ]; then
        log_debug 'file is bigger than 400MB, some site may not support it'
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

    PAGE=$(curl "$BASE_URL" -b "$COOKIEFILE" -c "$COOKIEFILE") || return
    FORM=$(grep_form_by_id "$PAGE" 'uu_upload' | break_html_lines)

    TOKEN=$(parse "token" ": '\([^']\+\)" <<< "$PAGE") || return

    # Retrieve complete hosting site list
    SITES_ALL=$(echo "$FORM" | grep 'checkbox' | parse_all_attr 'id=' value)

    if [ -z "$SITES_ALL" ]; then
        log_error 'Empty list, site updated?'
        return $ERR_FATAL
    else
        log_debug "Available sites:" $SITES_ALL
    fi

    if [ -n "$COUNT" ]; then
        if (( COUNT > 12 )); then
            COUNT=12
            log_error "Too big integer value for --count, set it to $COUNT"
        fi

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
        SITES_SEL=$(echo "$FORM" | parse_all_attr 'checked=' 'value')
    fi

    if [ -z "$SITES_SEL" ]; then
        log_debug 'Empty site selection. Nowhere to upload!'
        return $ERR_FATAL
    fi

    log_debug "Selected sites:" $SITES_SEL

    # Do not seem needed..
    #PAGE=$(curl "$BASE_URL/fnvalidator.php?fn=${DESTFILE};&fid=upfile_123;")

    # -b "$COOKIEFILE" not needed here
    #PAGE=$(curl_with_log \
    #    --user-agent "Shockwave Flash" \
    #    -F "Filename=$DESTFILE" \
    #    -F "Filedata=@$FILE;filename=$DESTFILE" \
    #    -F 'folder=/uploads' -F 'Upload=Submit Query' \
    #    "$BASE_URL/uploadify/uploadify.php") || return

    PAGE=$(curl_with_log -b "$COOKIEFILE" \
        -F "Filedata=@$FILE;filename=$DESTFILE" \
        -F 'timestamp=' \
        -F "token=$TOKEN" \
        "$BASE_URL/uploadify/uploadifive.php") || return

    # Filename can be renamed if "slot" already taken!
    # {"fileName": "RFC-all.tar.gz"}
    DESTFILE=$(echo "$PAGE" | parse 'fileName' ':[[:space:]]*"\([^"]\+\)"')
    log_debug "filename=$DESTFILE"

    # Some basic base64 encoding:
    # > FilesNames +=value + '#0#' + filesCompletedSize[key]+ ';0;';
    # > submitData = filesNames + '@e@' + email + '#H#' + selectedHost +'#P#' + pass + '#SC#' + scanvirus;
    # Example: RFC-all.tar.gz#0#225280;0;@e@#H#turbobit;hotfile;#P#
    DATA=$(echo "$SITES_SEL" | replace_all ' ' ';' | replace_all $'\r' '' | replace_all $'\n' ';')

    log_debug "sites=$DATA"
    DATA=$(echo "${DESTFILE}#0#${SZ};0;@e@#H#${DATA};#P#${LINK_PASSWORD}#SC#" | base64 --wrap=0)
    PAGE=$(curl -b "$COOKIEFILE" --referer "$BASE_URL" \
        "$BASE_URL/process.php?data=$DATA") || return

    if [ -n "$FULL_LINK" ]; then
        echo "$PAGE" | parse_attr 'getElementById("link1")' 'href' || return
    else
        echo "$PAGE" | parse_attr 'getElementById("link2")' 'href' || return
    fi

    return 0
}

# List links from a mirrorcreator link
# $1: mirrorcreator link
# $2: recurse subfolders (ignored here)
# stdout: list of links
mirrorcreator_list() {
    local URL=$1
    local PAGE STATUS LINKS NAME REL_URL
    if match '^https' "$URL"; then
        local BASE_URL='https://www.mirrorcreator.com'
    else
        local BASE_URL='http://www.mirrorcreator.com'
    fi

    PAGE=$(curl -L "$URL") || return

    if match '<h2.*Links Unavailable' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    #NAMES=( $(echo "$PAGE" | parse_all 'Success' '\.gif"[[:space:]]alt="\([^"]*\)') )
    NAME=$(parse_tag 'h3' <<< "$PAGE") || return

    # mstat.php
    STATUS=$(echo "$PAGE" | parse 'mstat\.php' ',[[:space:]]"\([^"]*\)",') || return
    PAGE=$(curl -L "$BASE_URL$STATUS") || return

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'Success' href) || return
    if [ -z "$LINKS" ]; then
        return $ERR_LINK_DEAD
    fi

    while read REL_URL; do
        test "$REL_URL" || continue

        PAGE=$(curl "$BASE_URL$REL_URL") || return
        URL=$(echo "$PAGE" | parse_tag 'redirecturl' div) || return

        # Error : Selected hosting site is no longer available.
        if ! match '^Error' "$URL"; then
            echo "$URL"
            echo "$NAME"
        else
            log_debug "$URL ($NAME)"
        fi
    done <<< "$LINKS"
}
