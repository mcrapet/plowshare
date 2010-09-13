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
# Output URL to standard output

set -e

VERSION="0.9.3"
MODULES="rapidshare megaupload mediafire 2shared zshare"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,,version,,Return plowup version
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
    echo "Usage: plowup [OPTIONS] [MODULE_OPTIONS] FILE [FILE2] [...] MODULE[:DESTNAME]"
    echo
    echo "  Upload a file (or files) to a file-sharing site."
    echo
    echo "  Available modules: $MODULES"
    echo
    echo "Global options:"
    echo
    debug_options "$OPTIONS" "  "
    debug_options_for_modules "$MODULES" "UPLOAD"
}

#
# Main
#

MODULE_OPTIONS=$(get_modules_options "$MODULES" UPLOAD)
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
test $# -ge 2 || { usage; exit 1; }
set_exit_trap

# *FILES, DESTINATION = $@
FILES=("${@:(1):$#-1}")
DESTINATION=${@:(-1)}
IFS=":" read MODULE DESTFILE <<< "$DESTINATION"

# Ignore DESTFILE when uploading multiple files (it makes no sense there)
if [ "$#" -gt '2' -a ! -z "$DESTFILE" ]; then
    log_notice "several files requested, ignore destination name"
    DESTFILE=""
fi

RETVAL=0
for FILE in "${FILES[@]}"; do
    if ! grep -w -q "$MODULE" <<< "$MODULES"; then
        log_error "unsupported module ($MODULE)"
        RETVAL=3
        continue
    fi
    FUNCTION=${MODULE}_upload
    log_notice "Starting upload ($MODULE): $FILE"
    test "$DESTFILE" && log_notice "Destination file: $DESTFILE"
    $FUNCTION "${UNUSED_OPTIONS[@]}" "$FILE" "$DESTFILE" || RETVAL=3
done

exit $RETVAL
