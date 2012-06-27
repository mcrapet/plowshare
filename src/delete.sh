#!/bin/bash -e
#
# Delete a file from file sharing servers
# Copyright (c) 2010-2012 Plowshare team
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


VERSION="GIT-snapshot"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,,version,,Return plowdel version
VERBOSE,v:,verbose:,LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
INTERFACE,i:,interface:,IFACE,Force IFACE network interface
NO_PLOWSHARERC,,no-plowsharerc,,Do not use plowshare.conf config file
"


# This function is duplicated from download.sh
absolute_path() {
    local SAVED_PWD=$PWD
    TARGET="$1"

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
        DIR=$PWD
    done

    if [ -f "$TARGET" ]; then
        DIR=$(dirname "$TARGET")
    else
        DIR=$TARGET
    fi

    cd -P "$DIR"
    TARGET=$PWD
    cd "$SAVED_PWD"
    echo "$TARGET"
}

# Print usage
# Note: $MODULES is a multi-line list
usage() {
    echo 'Usage: plowdel [OPTIONS] [MODULE_OPTIONS] URL...'
    echo
    echo '  Delete a file-link from a file sharing site.'
    echo '  Available modules:' $MODULES
    echo
    echo 'Global options:'
    echo
    print_options "$OPTIONS" '  '
    print_module_options "$MODULES" 'DELETE'
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'delete') || exit
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Get configuration file options. Command-line is not parsed yet.
match '--no-plowsharerc' "$*" || \
    process_configfile_options 'Plowdel' "$OPTIONS"

MODULE_OPTIONS=$(get_all_modules_options "$MODULES" DELETE)
eval "$(process_options 'plowdel' "$OPTIONS$MODULE_OPTIONS" "$@")"

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

if [ $# -lt 1 ]; then
    log_error "plowdel: no URL specified!"
    log_error "plowdel: try \`plowdel --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

set_exit_trap

RETVALS=()
DCOOKIE=$(create_tempfile) || exit

for URL in "$@"; do

    if [ -z "$URL" ]; then
        log_debug "empty argument, skipping"
        continue
    fi

    MODULE=$(get_module "$URL" "$MODULES")
    if [ -z "$MODULE" ]; then
        log_error "Skip: no module for URL ($URL)"
        RETVALS=(${RETVALS[@]} $ERR_NOMODULE)
        continue
    fi

    # Get configuration file module options
    test -z "$NO_PLOWSHARERC" && \
        process_configfile_module_options 'Plowdel' "$MODULE" 'DELETE'

    FUNCTION=${MODULE}_delete
    log_notice "Starting delete ($MODULE): $URL"

    :> "$DCOOKIE"
    DRETVAL=0
    $FUNCTION "${UNUSED_OPTIONS[@]}" "$DCOOKIE" "$URL" || DRETVAL=$?

    if [ $DRETVAL -eq 0 ]; then
        log_notice "File removed successfully"
    elif [ $DRETVAL -eq $ERR_LINK_NEED_PERMISSIONS ]; then
        log_error "Anonymous users cannot delete links"
    elif [ $DRETVAL -eq $ERR_LINK_DEAD ]; then
        log_error "Not found or already deleted"
    elif [ $DRETVAL -eq $ERR_LOGIN_FAILED ]; then
        log_error "Login process failed. Bad username/password or unexpected content"
    fi
    RETVALS=(${RETVALS[@]} $DRETVAL)
done

rm -f "$DCOOKIE"

if [ ${#RETVALS[@]} -eq 0 ]; then
    exit 0
elif [ ${#RETVALS[@]} -eq 1 ]; then
    exit ${RETVALS[0]}
else
    log_debug "retvals:${RETVALS[@]}"
    # Drop success values
    RETVALS=(${RETVALS[@]/#0*} -$ERR_FATAL_MULTIPLE)

    exit $((ERR_FATAL_MULTIPLE + ${RETVALS[0]}))
fi
