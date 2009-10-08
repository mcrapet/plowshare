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

# Upload a file to file sharing servers. 
#
# Output URL to standard output
#
# Dependencies: curl, getopt
#
# Web: http://code.google.com/p/plowshare
# Contact: Arnau Sanchez <tokland@gmail.com>.
#
#
set -e

VERSION="0.8.1"
MODULES="rapidshare megaupload 2shared"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,v,version,,Return plowdown version
QUIET,q,quiet,,Don't print debug messages
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
    debug "Usage: plowup [OPTIONS] [MODULE_OPTIONS] FILE MODULE[:DESTNAME]"
    debug
    debug "  Upload a file to a file sharing site."
    debug
    debug "  Available modules: $MODULES"
    debug
    debug "Global options:"
    debug
    debug_options "$OPTIONS" "  " 
    debug_options_for_modules "$MODULES" "UPLOAD"    
}

# Main
#

MODULE_OPTIONS=$(get_modules_options "$MODULES" UPLOAD)
eval "$(process_options "plowshare" "$OPTIONS $MODULE_OPTIONS" "$@")"

test "$HELP" && { usage; exit 2; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

test $# -eq 2 || { usage; exit 1; } 

FILE=$1
DESTINATION=$2
IFS=":" read MODULE DESTFILE <<< "$DESTINATION"

# Test that file exists (ignore URLs)
if ! match "^\(http://\)" "$FILE" && ! test -f "$FILE"; then
    error "file does not exist: $FILE"
    exit 3
fi

grep -w -q "$MODULE" <<< "$MODULES" ||
    { error "unsupported module ($MODULE)"; exit 4; }
FUNCTION=${MODULE}_upload
debug "starting upload ($MODULE)"
$FUNCTION "${UNUSED_OPTIONS[@]}" "$FILE" "$DESTFILE" || exit 5
