#!/bin/bash
#
# Download files from file-sharing servers. Currently supported:
#
# - Megaupload (download & upload)
# - Rapidshare (download)
# - 2Shared (download)
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

# Get library directory
LIBDIR=$(dirname "$(readlink -f "$(type -P $0)")")

# Common library
source $LIBDIR/lib.sh

# Modules
source $LIBDIR/module_rapidshare.sh
source $LIBDIR/module_megaupload.sh
source $LIBDIR/module_2shared.sh

# Get supported modules
VARPREFIX="PLOWSHARE_"
MODULES=$(set | grep "^$VARPREFIX" | cut -d"=" -f1 | sed "s/^$VARPREFIX//" | \
    tr '[A-Z]' '[a-z]' | sort | xargs -d"\n" | xargs | sed "s/ /, /g" )        

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

get_module() {
    set | grep "^$VARPREFIX" | cut -d"=" -f1 | while read VARNAME; do
        REGEXP="${!VARNAME}"
        MODULE=$(echo $VARNAME | sed "s/^$VARPREFIX//" | tr '[A-Z]' '[a-z]')
        match "$REGEXP" "$1" && { echo $MODULE; return; } || true    
    done     
} 

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

check_exec "curl" "curl not found"

unset USER PASSWORD
eval set -- "$(getopt -o a: --long auth: -n '$(basename $0)' -- "$@")"
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
            debug "start download: $URL"
            MODULE=$(get_module "$URL")
            test "$MODULE" || { debug "no module recognizes URL: $URL"; continue; }
            FUNCTION=${MODULE}_download 
            if ! declare -f "$FUNCTION" &>/dev/null; then 
                debug "module does not currently implement download: $MODULE"
                continue
            fi
            FILE_URL=$($FUNCTION "$URL" "$USER" "$PASSWORD") && 
                FILENAME=$(basename "$FILE_URL" | sed "s/?.*$//") && 
                curl -o "$FILENAME" "$FILE_URL" && 
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
    debug "starting upload to $MODULE: $FILE"
    if ! declare -f "$FUNCTION" &>/dev/null; then 
        debug "module does not implement upload: $MODULE"
        exit 2
    fi
    $FUNCTION "$FILE" "$USER" "$PASSWORD" "$DESCRIPTION" 
else
    debug "Unknown operation: $OPERATION"
    debug
    usage
    exit 1  
fi
