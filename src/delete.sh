#!/bin/bash
#
# Delete a file from file sharing servers
# Copyright (c) 2010 Arnau Sanchez
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

set -e

VERSION="0.9.3"
MODULES="2shared megaupload rapidshare zshare"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,,version,,Return plowdel version
VERBOSE,v:,verbose:,LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
"


# This function is duplicated from download.sh
absolute_path() {
    local SAVED_PWD="$PWD"
    TARGET="$1"

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
        DIR="$PWD"
    done

    if [ -f "$TARGET" ]; then
        DIR=$(dirname "$TARGET")
    else
        DIR="$TARGET"
    fi

    cd -P "$DIR"
    TARGET="$PWD"
    cd "$SAVED_PWD"
    echo "$TARGET"
}

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/lib.sh"
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Print usage
usage() {
    echo "Usage: plowdel [OPTIONS] [MODULE_OPTIONS] URL1 [[URL2] [...]]"
    echo
    echo "  Delete a file-link from a file sharing site."
    echo
    echo "  Available modules: $MODULES"
    echo
    echo "Global options:"
    echo
    debug_options "$OPTIONS" "  "
    debug_options_for_modules "$MODULES" "DELETE"
}

#
# Main
#

MODULE_OPTIONS=$(get_modules_options "$MODULES" DELETE)
eval "$(process_options "plowshare" "$OPTIONS $MODULE_OPTIONS" "$@")"

# Verify verbose level
if [ -n "$QUIET" ]; then
    VERBOSE=0
elif [ -n "$VERBOSE" ]; then
    [ "$VERBOSE" -gt "4" ] && VERBOSE=4
else
    VERBOSE=2
fi

test "$HELP" && { usage; exit 2; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }
test $# -ge 1 || { usage; exit 1; }
set_exit_trap

RETVAL=0

for URL in "$@"; do
    MODULE=$(get_module "$URL" "$MODULES")

    if test -z "$MODULE"; then
        log_error "Skip: no module for URL ($URL)"
        RETVAL=4
        continue
    fi

    FUNCTION=${MODULE}_delete
    log_notice "Starting delete ($MODULE): $URL"
    $FUNCTION "${UNUSED_OPTIONS[@]}" "$URL" || RETVAL=5
done

exit $RETVAL
