#!/bin/bash
#
# Download and upload files from file sharing servers. 
#
# In download mode, output files downloaded to standard output (one per line).
# In upload mode, output generated URL.
#
# Dependencies: curl.
#
# Web: http://code.google.com/p/plowshare
# Contact: Arnau Sanchez <tokland@gmail.com>.
#
# License: GNU GPL v3.0: http://www.gnu.org/licenses/gpl-3.0-standalone.html
#
set -e

# Supported modules
MODULES="rapidshare megaupload 2shared"

# Get library directory
LIBDIR=$(dirname "$(readlink -f "$(type -P $0)")")
MODULESDIR=$LIBDIR/modules

# Common library
source $LIBDIR/lib.sh

# Load modules
for MODULE in $MODULES; do
    source $MODULESDIR/$MODULE.sh
done

# Guess is item is a rapidshare URL, a generic URL (to start a download)
# or a file with links
#
process_item() {
    ITEM=$1
    if match "^\(http://\)" "$ITEM"; then
        echo "$ITEM"
    else
        grep -v "^[[:space:]]*\(#\|$\)" -- "$ITEM"
    fi
}

# Get module name from URL
#
# $1: URL 
get_module() {
    URL=$1
    for MODULE in $MODULES; do
        VAR=MODULE_$(echo $MODULE | tr '[a-z]' '[A-Z]')_REGEXP_URL
        match "${!VAR}" "$URL" && { echo $MODULE; return; } || true    
    done     
} 

# Print usage
#
usage() {
    debug "Download and upload files from file sharing servers."
    debug
    debug "  Download: plowdown [OPTIONS] URL|FILE [URL|FILE ...]"
    debug "  Upload: plowup [OPTIONS] module FILE DESCRIPTION"
    debug
    debug "Options:"
    debug 
    debug "  -a USER:PASSWORD, --auth=USER:PASSWORD"
    debug
    debug "Available modules: $MODULES."
}

# Main
#

test $# -ge 2 || { usage; exit 1; } 

check_exec "curl" || { debug "curl not found"; exit 2; }

unset USER PASSWORD
eval set -- "$(getopt -o a: --long auth: -n 'plowshare' -- "$@")"
while true; do
    case "$1" in
        -a|--auth) 
            IFS=":" read USER PASSWORD <<< "$2"; shift 2;;
        --) 
            shift; break;;
    esac
done 

OPERATION=$1
shift

if test "$OPERATION" = "download"; then
    for ITEM in "$@"; do
        process_item "$ITEM" | while read URL; do
            MODULE=$(get_module "$URL")
            test "$MODULE" || { debug "no module recognizes URL: $URL"; continue; }
            FUNCTION=${MODULE}_download 
            if ! check_function "$FUNCTION"; then 
                debug "module does not currently implement download: $MODULE"
                continue
            fi
            debug "start download ($MODULE): $URL"
            FILE_URL=$($FUNCTION "$URL" "$USER" "$PASSWORD") && 
                FILENAME=$(basename "$FILE_URL" | sed "s/?.*$//") && 
                curl --globoff -o "$FILENAME" "$FILE_URL" && 
                echo $FILENAME ||
                debug "could not download: $URL" 
        done
    done
elif test "$OPERATION" = "upload"; then
    MODULE=$1    
    FILE=$2
    DESCRIPTION=$3
    FUNCTION=${MODULE}_upload
    if ! echo "$MODULES" | grep -q "\<$MODULE\>"; then
        debug "unsupported module: $MODULE"
        exit 2        
    fi
    if ! check_function "$FUNCTION"; then 
        debug "module does not implement upload: $MODULE"
        exit 3
    fi
    debug "starting upload ($MODULE): $FILE"
    $FUNCTION "$FILE" "$USER" "$PASSWORD" "$DESCRIPTION" 
else
    debug "Unknown operation: $OPERATION (valid: download | upload)"
    debug
    usage
    exit 1  
fi
