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
OPTIONS="a:,auth:,AUTH,USER:PASSWORD 
q,quiet,QUIET 
l,link-only,LINK_ONLY
p:,file-password:,FILEPASSWORD,STRING
"

# Get library directory
LIBDIR=$(dirname "$(readlink -f "$(type -P $0 || echo $0)")")
source $LIBDIR/lib.sh
for MODULE in $MODULES; do
    source $LIBDIR/modules/$MODULE.sh
done

# Guess is item is a rapidshare URL, a generic URL (to start a download)
# or a file with links (discard empty/repeated lines and comments) 
#
process_item() {
    ITEM=$1
    if match "^\(http://\)" "$ITEM"; then
        echo "$ITEM"
    else
        grep -v "^[[:space:]]*\(#\|$\)" -- "$ITEM" | uniq
    fi
}

# Print usage
#
usage() {
    debug "Download files from file sharing servers."
    debug
    debug "  $(basename $0) [OPTIONS] URL|FILE [URL|FILE ...]"
    debug
    debug "Available modules: $MODULES."
    debug
    debug "Options:"
    debug
    debug_options "$OPTIONS" "    "
    debug
}

# Main
#

check_exec "curl" || { debug "curl not found"; exit 2; }
check_exec "recode" || { debug "recode not found"; exit 2; }
eval "$(process_options "$OPTIONS" "$@")"

if test "$QUIET"; then
    function debug() { :; } 
    function curl() { $(type -P curl) -s "$@"; }
fi

test $# -ge 1 || { usage; exit 1; } 

test "$AUTH" && OPTIONS="-a $AUTH" || OPTIONS=

# Exit with code 0 if all links are downloaded succesfuly (4 otherwise)
DERROR=4
RETVAL=0
for ITEM in "$@"; do
    process_item "$ITEM" | while read URL; do
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
        FILE_URL=$($FUNCTION $OPTIONS "$URL")         
        if test "$LINK_ONLY"; then
            echo $FILE_URL
        else 
            FILENAME=$(basename "$FILE_URL" | recode html..) &&
            curl --globoff -o "$FILENAME" "$FILE_URL" &&
            echo $FILENAME || 
            { debug "error downloading: $URL"; RETVAL=$DERROR; }
        fi 
    done
done

exit $RETVAL
