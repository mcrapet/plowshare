#!/bin/bash
#
# Upload a file from file sharing servers. 
#
# Output URL to standard output (one per line).
#
# Dependencies: curl, getopt
#
# Web: http://code.google.com/p/plowshare
# Contact: Arnau Sanchez <tokland@gmail.com>.
#
# License: GNU GPL v3.0: http://www.gnu.org/licenses/gpl-3.0-standalone.html
#
set -e

VERSION="0.4.2"
MODULES="rapidshare megaupload 2shared"
OPTIONS="
GETVERSION,v,version,,Return plowdown version
QUIET,q,quiet,,Don't print error nor debug messages
"

# Get library directory
LIBDIR=$(dirname "$(readlink -f "$(which "$0")")")
source $LIBDIR/lib.sh
for MODULE in $MODULES; do
    source $LIBDIR/modules/$MODULE.sh
done

# Print usage
#
usage() {
    debug "$(basename $0) [OPTIONS] [MODULE_OPTIONS] MODULE:FILE"
    debug
    debug "  Upload a file to file sharing server."
    debug
    debug "  Available modules: $MODULES"
    debug
    debug "Global options:"
    debug
    debug_options "$OPTIONS" "  " 
    debug_options_for_modules "$MODULES" "UPLOAD"    
    debug
}

# Main
#

check_exec "curl" || { debug "curl not found"; exit 2; }
MODULE_OPTIONS=$(get_modules_options "$MODULES" UPLOAD)
eval "$(process_options "plowshare" "$OPTIONS $MODULE_OPTIONS" "$@")"

test "$GETVERSION" && { echo "$VERSION"; exit 0; }
if test "$QUIET"; then
    function debug() { :; } 
    function curl() { $(type -P curl) -s "$@"; }
fi

test $# -eq 1 || { usage; exit 1; } 

IFS=":" read MODULE FILE <<< "$@"
FUNCTION=${MODULE}_upload
shift
if ! match "\<$MODULE\>" "$MODULES"; then
    debug "unsupported module: $MODULE"
    exit 3
fi
if ! check_function "$FUNCTION"; then 
    debug "module does not implement upload: $MODULE"
    exit 4
fi
if ! test -f "$FILE"; then
    debug "file does not exist: $FILE"
    exit 5
fi
debug "starting upload ($MODULE)"
$FUNCTION "${UNUSED_OPTIONS[@]}" "$FILE" || exit 2
