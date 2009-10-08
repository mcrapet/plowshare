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

VERSION="0.8.1"
MODULES="rapidshare megaupload 2shared badongo mediafire 4shared zshare depositfiles"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,v,version,,Return plowdown version
QUIET,q,quiet,,Don't print debug messages 
LINK_ONLY,l,link-only,,Return only file link 
MARK_DOWN,m,mark-downloaded,,Mark downloaded links in (regular) FILE arguments
OUTPUT_DIR,o:,output-directory:,DIRECTORY,Directory where files will be saved
LIMIT_RATE,r:,--limit-rate:,SPEED,Limit speed to bytes/sec (suffixes: k=Kb, m=Mb, g=Gb) 
"

# Get library directory
LIBDIR=$(dirname "$(readlink -f "$(which "$0")")")
EXTRASDIR=$LIBDIR/modules/extras

source $LIBDIR/lib.sh
for MODULE in $MODULES; do
    source $LIBDIR/modules/$MODULE.sh
done

# Guess is item is a rapidshare URL, a generic URL (to start a download)
# or a file with links (discard empty/repeated lines and comments)- 
#
process_item() {
    ITEM=$1
    if match "^http://" "$ITEM"; then
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
}

# download MODULE URL FUNCTION_OPTIONS
download() {
    local MODULE=$1
    local URL=$2
    local LINK_ONLY=$3
    local LIMIT_RATE=$4
    local TYPE=$5
    local MARK_DOWN=$6
    local OUTPUT_DIR=$7
    shift 7
    
    FUNCTION=${MODULE}_download 
    debug "start download ($MODULE): $URL"

    while true; do      
        FILE_URL=$($FUNCTION "$@" "$URL") && DRETVAL=0 || DRETVAL=$?
        test $DRETVAL -eq 255 && 
            { debug "Link active: $URL"; echo "$URL"; break; }
        test $DRETVAL -ne 0 -o -z "$FILE_URL" && 
            { error "error on function: $FUNCTION"; RETVAL=$DERROR; break; }
        debug "file URL: $FILE_URL"
        
        if test "$LINK_ONLY"; then
            echo "$FILE_URL"
        else
            CURL=("curl") 
            continue_downloads "$MODULE" && CURL=($CURL "-C -")
            test "$LIMIT_RATE" && CURL=($CURL "--limit-rate $LIMIT_RATE")
            FILENAME=$(basename "$FILE_URL" | sed "s/?.*$//" | tr -d '\r\n' |
                recode html..utf8)
            test "$OUTPUT_DIR" && FILENAME="$OUTPUT_DIR/$FILENAME"
            local DRETVAL=0
            ${CURL[@]} -y60 -f --globoff -o "$FILENAME" "$FILE_URL" &&
                echo "$FILENAME" || DRETVAL=$?
            if [ $DRETVAL -eq 22 -o $DRETVAL -eq 18 -o $DRETVAL -eq 28 ]; then
                local WAIT=60
                debug "curl failed with retcode $DRETVAL"
                debug "retry after a safety wait ($WAIT seconds)"
                sleep $WAIT
                continue
            elif [ $DRETVAL -ne 0 ]; then
                error "error downloading: $URL"
                RETVAL=$DERROR
                break
            fi            
        fi
        
        if test "$TYPE" = "file" -a "$MARK_DOWN"; then 
            sed -i "s|^[[:space:]]*\($URL\)[[:space:]]*$|#\1|" "$ITEM" && 
                debug "link marked as downloaded in file: $ITEM" ||
                error "error marking link as downloaded in file: $ITEM"
        fi
        break
    done 
}

# Main
#

MODULE_OPTIONS=$(get_modules_options "$MODULES" DOWNLOAD)
eval "$(process_options plowshare "$OPTIONS $MODULE_OPTIONS" "$@")"

test "$HELP" && { usage; exit 2; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }
 
test $# -ge 1 || { usage; exit 1; }

# Exit with code 0 if all links are downloaded succesfuly (DERROR otherwise)
DERROR=5
RETVAL=0
for ITEM in "$@"; do
    for INFO in $(process_item "$ITEM"); do
        IFS="|" read TYPE URL <<< "$INFO"
        MODULE=$(get_module "$URL" "$MODULES")
        test -z "$MODULE" && 
            { debug "no module for URL: $URL"; RETVAL=$DERROR; continue; }
        download "$MODULE" "$URL" "$LINK_ONLY" "$LIMIT_RATE" "$TYPE" \
            "$MARK_DOWN" "$OUTPUT_DIR" "${UNUSED_OPTIONS[@]}"            
    done
done

exit $RETVAL
