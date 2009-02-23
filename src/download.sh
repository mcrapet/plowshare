#!/bin/bash
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
# License: GNU GPL v3.0: http://www.gnu.org/licenses/gpl-3.0-standalone.html
#
set -e

# Supported modules
MODULES="rapidshare megaupload 2shared"
OPTIONS="
q,quiet,QUIET 
l,link-only,LINK_ONLY
m,mark-downloaded,MARK_DOWNLOADED
"

# Get library directory
LIBDIR=$(dirname "$(readlink -f "$(type -P $0 || echo $0)")")
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
        VAR=MODULE_$(echo $MODULE | tr '[a-z]' '[A-Z]')_REGEXP_URL
        match "${!VAR}" "$URL" && { echo $MODULE; return; } || true    
    done
    return 1     
}

# Guess is item is a rapidshare URL, a generic URL (to start a download)
# or a file with links (discard empty/repeated lines and comments)- 
#
process_item() {
    ITEM=$1
    if match "^\(http://\)" "$ITEM"; then
        echo "url" "$ITEM"
    else
        grep -v "^[[:space:]]*\(#\|$\)" -- "$ITEM" | while read LINE; do
            if test "$ITEM" != "-" -a -f "$ITEM"; then
                TYPE="file"
            else
                TYPE="url"
            fi 
            echo "$TYPE" $LINE
        done
    fi
}

# Print usage
#
usage() {
    debug "Download files from file sharing servers."
    debug
    debug "  $(basename $0) [OPTIONS] [MODULE_OPTIONS] URL|FILE [URL|FILE ...]"
    debug
    debug "Available modules: $MODULES"
    debug
    debug "Global options:"
    debug
    debug_options "$OPTIONS" "  "
    debug_options_for_modules "$MODULES" "DOWNLOAD"    
    debug
}

# Main
#

check_exec "curl" || { debug "curl not found"; exit 2; }
check_exec "recode" || { debug "recode not found"; exit 2; }

MODULE_OPTIONS=$(get_modules_options "$MODULES" DOWNLOAD)
eval "$(process_options plowshare "$OPTIONS $MODULE_OPTIONS" "$@")"

if test "$QUIET"; then
    function debug() { :; } 
    function curl() { $(type -P curl) -s "$@"; }
fi

test $# -ge 1 || { usage; exit 1; } 

# Exit with code 0 if all links are downloaded succesfuly (DERROR otherwise)
DERROR=4
RETVAL=0
for ITEM in "$@"; do
    process_item "$ITEM" | while read TYPE URL; do
        MODULE=$(get_module "$URL" "$MODULES")
        if ! test "$MODULE"; then 
            debug "no module recognizes this URL: $URL"
            RETVAL=$DERROR
            continue
        fi
        FUNCTION=${MODULE}_download 
        if ! check_function "$FUNCTION"; then 
            debug "module does not implement download: $MODULE"
            RETVAL=$DERROR
            continue
        fi
        debug "start download ($MODULE): $URL"
        MODULE_OPTIONS=$(get_options_for_module "$MODULE" "DOWNLOAD")
        FILE_URL=$($FUNCTION "${UNUSED_OPTIONS[@]}" "$URL")
        if test "$LINK_ONLY"; then
            echo $FILE_URL
        else 
            FILENAME=$(basename "$FILE_URL" | recode html..) &&
            curl --globoff -o "$FILENAME" "$FILE_URL" &&
            echo $FILENAME || 
            { debug "error downloading: $URL"; RETVAL=$DERROR; continue; }
        fi
        if test "$TYPE" = "file" -a "$MARK_DOWNLOADED"; then 
            sed -i "s|^[[:space:]]*\($URL\)[[:space:]]*$|#\1|" "$ITEM" && 
            debug "link marked as downloaded in input file: $ITEM" ||
            debug "error marking link as downloaded in input file: $ITEM"
        fi 
    done
done

exit $RETVAL
