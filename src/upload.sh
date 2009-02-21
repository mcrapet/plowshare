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

# Supported modules
MODULES="rapidshare megaupload 2shared"

# Get library directory
LIBDIR=$(dirname "$(readlink -f "$(which $0)")")
source $LIBDIR/lib.sh
for MODULE in $MODULES; do
    source $LIBDIR/modules/$MODULE.sh
done

# Show usage info for modules
debug_options_for_modules() {
    MODULES=$1
    NAME=$2
    for MODULE in $MODULES; do
        VAR="MODULE_$(echo $MODULE | tr '[a-z]' '[A-Z]')_${NAME}_OPTIONS"
        OPTIONS=${!VAR}
        if test "$OPTIONS"; then
            debug
            debug "Options for module <$MODULE>:"
            debug
            for OPTION in $OPTIONS; do
                IFS="," read SHORT LONG VAR VALUE <<< "$OPTION"
                echo "$HELP" | while read LINE; do
                    debug "  -${SHORT%:} $VALUE, --${LONG%:}=$VALUE"
                done
            done
        fi        
    done
}

# Print usage
#
usage() {
    debug "Upload a file to file sharing server."
    debug
    debug "  $(basename $0) [OPTIONS] MODULE -- [MODULE_OPTIONS] FILE"
    debug
    debug "Available modules: $MODULES."
    debug
    debug "Options:"
    debug
    debug "  -q, --quiet: Don't print debug or error messages" 
    debug_options_for_modules "$MODULES" "UPLOAD"    
    debug
}

# Main
#

check_exec "curl" || { debug "curl not found"; exit 2; }
eval "$(process_options "q,quiet,QUIET" "$@")" 

if test "$QUIET"; then
    function debug() { :; } 
    function curl() { $(type -P curl) -s "$@"; }
fi

test $# -ge 2 || { usage; exit 1; } 

MODULE=$1    
FUNCTION=${MODULE}_upload
shift
if ! match "\<$MODULE\>" "$MODULES"; then
    debug "unsupported module: $MODULE"
    exit 2        
fi
if ! check_function "$FUNCTION"; then 
    debug "module does not implement upload: $MODULE"
    exit 3
fi
debug "starting upload ($MODULE)"
$FUNCTION "$@" || exit 4
