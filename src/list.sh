#!/bin/bash -e
#
# Retreive list of links from a shared-folder (sharing site) url
# Copyright (c) 2010-2011 Plowshare team
#
# Output links (one per line) on standard output.
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


VERSION="SVN-snapshot"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,,version,,Return plowlist version
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

# Print usage
usage() {
    echo "Usage: plowlist [OPTIONS] [MODULE_OPTIONS] URL..."
    echo
    echo "  Retreive list of links from a shared-folder (sharing site) url."
    echo "  Available modules:" $(echo "$MODULES" | tr '\n' ' ')
    echo
    echo "Global options:"
    echo
    debug_options "$OPTIONS" "  "
    debug_options_for_modules "$MODULES" "LIST"
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/core.sh"
MODULES=$(grep_config_modules 'list') || exit $?
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

MODULE_OPTIONS=$(get_modules_options "$MODULES" LIST)
eval "$(process_options "plowshare" "$OPTIONS $MODULE_OPTIONS" "$@")"

# Verify verbose level
if [ -n "$QUIET" ]; then
    VERBOSE=0
elif [ -n "$VERBOSE" ]; then
    [ "$VERBOSE" -gt "4" ] && VERBOSE=4
else
    VERBOSE=2
fi

test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }
test $# -ge 1 || { usage; exit $ERR_FATAL; }
set_exit_trap

RETVALS=()
for URL in "$@"; do
    MODULE=$(get_module "$URL" "$MODULES")

    if test -z "$MODULE"; then
        log_error "Skip: no module for URL ($URL)"
        RETVALS=(${RETVALS[@]} $ERR_NOMODULE)
        continue
    fi

    FUNCTION=${MODULE}_list
    log_notice "Retreiving list ($MODULE): $URL"
    $FUNCTION "${UNUSED_OPTIONS[@]}" "$URL" || \
        RETVALS=(${RETVALS[@]} "$?")
done

if [ ${#RETVALS[@]} -eq 0 ]; then
    exit 0
elif [ ${#RETVALS[@]} -eq 1 ]; then
    exit ${RETVALS[0]}
else
    log_debug "retvals:${RETVALS[@]}"
    exit $((ERR_FATAL_MULTIPLE + ${RETVALS[0]}))
fi
