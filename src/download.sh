#!/bin/bash
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
#

# Download files from file sharing servers. 
#
# Output filenames path to standard output (one per line).
#
# Dependencies: curl, getopt, recode
#
# Web: http://code.google.com/p/plowshare
# Contact: Arnau Sanchez <tokland@gmail.com>.
#
#
set -e

VERSION="0.6"
MODULES="rapidshare megaupload 2shared badongo mediafire"
OPTIONS="
GETVERSION,v,version,,Return plowdown version
QUIET,q,quiet,,Don't print debug messages 
LINK_ONLY,l,link-only,,Return only file link 
MARK_DOWNLOADED,m,mark-downloaded,,Mark downloaded links in FILE arguments
"

# Get library directory
LIBDIR=$(dirname "$(readlink -f "$(which "$0")")")
EXTRASDIR=$LIBDIR/modules/extras

source $LIBDIR/lib.sh
for MODULE in $MODULES; do
    source $LIBDIR/modules/$MODULE.sh
done

# Get module name from URL link
#
# $1: URL 
get_module() {
    URL=$1
    MODULES=$2
    for MODULE in $MODULES; do
        VAR=MODULE_$(echo $MODULE | uppercase)_REGEXP_URL
        match "${!VAR}" "$URL" && { echo $MODULE; return; } || true    
    done
}

# Guess is item is a rapidshare URL, a generic URL (to start a download)
# or a file with links (discard empty/repeated lines and comments)- 
#
process_item() {
    ITEM=$1
    if match "^\(http://\)" "$ITEM"; then
        echo "url|$ITEM"
    else
        grep -v "^[[:space:]]*\(#\|$\)" -- "$ITEM" | while read URL; do
            test "$ITEM" != "-" -a -f "$ITEM" &&
                TYPE="file" || TYPE="url"
            echo "$TYPE|$URL"
        done
    fi
}

# Print usage
#
usage() {
    debug "Usage: plowdown [OPTIONS] [MODULE_OPTIONS] URL|FILE [URL|FILE ...]"
    debug
    debug "  Download files from file sharing servers."
    debug
    debug "  Available modules: $MODULES"
    debug
    debug "Global options:"
    debug
    debug_options "$OPTIONS" "  "
    debug_options_for_modules "$MODULES" "DOWNLOAD"    
    debug
}

# Main
#

MODULE_OPTIONS=$(get_modules_options "$MODULES" DOWNLOAD)
eval "$(process_options plowshare "$OPTIONS $MODULE_OPTIONS" "$@")"

test "$GETVERSION" && { echo "$VERSION"; exit 0; }
 
if test "$QUIET"; then
    function debug() { :; } 
    function curl() { $(type -P curl) -s "$@"; }
fi

test $# -ge 1 || { usage; exit 1; } 

# Exit with code 0 if all links are downloaded succesfuly (DERROR otherwise)
DERROR=4
RETVAL=0
for ITEM in "$@"; do
    for INFO in $(process_item "$ITEM"); do
        IFS="|" read TYPE URL <<< "$INFO"
        MODULE=$(get_module "$URL" "$MODULES")
        if ! test "$MODULE"; then 
            debug "no module recognizes this URL: $URL"
            RETVAL=$DERROR
            continue
        fi
        FUNCTION=${MODULE}_download 
        debug "start download ($MODULE): $URL"
        
        FILE_URL=$($FUNCTION "${UNUSED_OPTIONS[@]}" "$URL")
        test "$FILE_URL" || 
            { echo "error on function: $FUNCTION"; RETVAL=$DERROR; continue; }
        debug "file URL: $FILE_URL"
        if test "$LINK_ONLY"; then
            echo "$FILE_URL"
        else 
            can_module_continue_downloads "$MODULE" &&
                CURL="curl -C -"|| CURL="curl"
            FILENAME=$(basename "$FILE_URL" | sed "s/?.*$//" | recode html..) &&
                $CURL --globoff -o "$FILENAME" "$FILE_URL" &&
                echo $FILENAME || 
                { error "error downloading: $URL"; RETVAL=$DERROR; continue; }
        fi
        if test "$TYPE" = "file" -a "$MARK_DOWNLOADED"; then 
            sed -i "s|^[[:space:]]*\($URL\)[[:space:]]*$|#\1|" "$ITEM" && 
                debug "link marked as downloaded in input file: $ITEM" ||
                error "error marking link as downloaded in input file: $ITEM"
        fi 
    done
done

exit $RETVAL
