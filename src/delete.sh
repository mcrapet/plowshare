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

# Delete a file from file sharing servers. 
#
# Dependencies: curl, getopt
#
# Web: http://code.google.com/p/plowshare
# Contact: Arnau Sanchez <tokland@gmail.com>.
#
set -e

VERSION="0.8"
MODULES="megaupload"
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
    debug "Usage: plowdel [OPTIONS] [MODULE_OPTIONS] URL1 [[URL2] [...]]"
    debug
    debug "  Delete a file-link from a file sharing site."
    debug
    debug "  Available modules: $MODULES"
    debug
    debug "Global options:"
    debug
    debug_options "$OPTIONS" "  " 
    debug_options_for_modules "$MODULES" "DELETE"    
}

# Main
#

MODULE_OPTIONS=$(get_modules_options "$MODULES" DELETE)
eval "$(process_options "plowshare" "$OPTIONS $MODULE_OPTIONS" "$@")"

test "$HELP" && { usage; exit 2; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }
test $# -ge 1 || { usage; exit 1; } 

for URL in "$@"; do 
  MODULE=$(get_module "$URL" "$MODULES")
  grep -w -q "$MODULE" <<< "$MODULES" ||
      { error "unsupported module ($MODULE)"; exit 4; }
  FUNCTION=${MODULE}_delete
  debug "starting delete ($MODULE): $URL"
  $FUNCTION "${UNUSED_OPTIONS[@]}" "$URL" || exit 5
done
