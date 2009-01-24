#!/bin/bash
#
# Download files from file-sharing servers. Currently supported:
#
# - Rapidshare (download)
# - Megaupload (download & upload)
# - 2Shared (download)
#
# Output files downloaded to standard output (one per line).
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
source $LIBDIR/rapidshare.sh
source $LIBDIR/megaupload.sh
source $LIBDIR/2shared.sh

VARPREFIX="DOWNSHARE_"

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

# Main
#

MODULES=$(set | grep "^$VARPREFIX" | cut -d"=" -f1 | \
    sed "s/^$VARPREFIX//" | tr '[A-Z]' '[a-z]' | sort | xargs -d"\n")
    
if test $# -lt 2; then
    debug "Download and upload file from file-sharing servers. Usage:"
    debug
    debug "  Download: plowdown [OPTIONS] URL|FILE [URL|FILE ...]"
    debug "  Upload: plowup [OPTIONS] module FILE DESCRIPTION"
    debug
    debug "Options:"
    debug 
    debug "  -a USER:PASSWORD, --a=USER:PASSWORD"
    debug
    debug "Available modules: $MODULES"
    exit 1
fi

check_exec "curl" "curl not found"

unset USER PASSWORD
eval set -- "$(getopt -o a: --long authentication: -n '$(basename $0)' -- "$@")"
while true; do
    case "$1" in
        -a|--authentication) 
            IFS=":" read USER PASSWORD <<< "$2"; shift 2 ;;
        --) shift ; break ;;
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
                FILENAME=$(basename "$FILE_URL") && 
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
        debug "module does not currently implement upload: $MODULE"
        exit 2
    fi
    $FUNCTION "$FILE" "$DESCRIPTION" "$USER" "$PASSWORD"
else
    debug "unknown command: $OPERATION"
    exit 1  
fi
