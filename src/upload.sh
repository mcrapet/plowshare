#!/bin/bash -e
#
# Upload a file to file sharing servers
# Copyright (c) 2010-2011 Plowshare team
#
# Output URL to standard output.
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
GETVERSION,,version,,Return plowup version
VERBOSE,v:,verbose:,LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
LIMIT_RATE,l:,limit-rate:,SPEED,Limit speed to bytes/sec (suffixes: k=Kb, m=Mb, g=Gb)
INTERFACE,i:,interface:,IFACE,Force IFACE interface
MAXRETRIES,r:,max-retries:,N,Set maximum retries for upload failures. 0 means no retry (default).
NAME_PREFIX,,name-prefix:,STRING,Prepend argument to each destination filename
NAME_SUFFIX,,name-suffix:,STRING,Append argument to each destination filename
NO_CURLRC,,no-curlrc,,Do not use curlrc config file
NO_PLOWSHARERC,,no-plowsharerc,,Do not use plowshare.conf config file
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
# Note: $MODULES is a multi-line list
usage() {
    echo 'Usage: plowup [OPTIONS] MODULE [MODULE_OPTIONS] URL|FILE[:DESTNAME]...'
    echo
    echo '  Upload file(s) to a file-sharing site.'
    echo '  Available modules:' $MODULES
    echo
    echo 'Global options:'
    echo
    print_options "$OPTIONS" '  '
    print_module_options "$MODULES" 'UPLOAD'
}

# Check if module name is contained in list
#
# $1: module name list (one per line)
# $2: module name
# $?: zero for found, non zero otherwie
# stdout: lowercase module name (if found)
module_exist() {
    N=$(echo "$2" | lowercase)
    while read MODULE; do
        if test "$N" = "$MODULE"; then
            echo "$N"
            return 0
        fi
    done <<< "$1"
    return 1
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'upload') || exit $?
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Get configuration file options. Command-line is not parsed yet.
match '--no-plowsharerc' "$@" || \
    process_configfile_options 'Plowup' "$OPTIONS"

MODULE_OPTIONS=$(get_all_modules_options "$MODULES" UPLOAD)
eval "$(process_options 'plowup' "$OPTIONS$MODULE_OPTIONS" "$@")"

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
test $# -lt 1 && { usage; exit $ERR_FATAL; }

if [ $# -eq 1 -a -f "$1" ]; then
    log_error "you must specify a module name"
    exit $ERR_NOMODULE
fi

# Check requested module
MODULE=$(module_exist "$MODULES" "$1") || {
    # Give a second try
    MODULE=$(module_exist "$MODULES" "${1//./_}") || {
        log_error "unsupported module ($1)"
        exit $ERR_NOMODULE
    }
}

log_report_info
log_report "plowup version $VERSION"

set_exit_trap

FUNCTION=${MODULE}_upload

shift 1

RETVALS=()
UPCOOKIE=$(create_tempfile)

# Get configuration file module options
test -z "$NO_PLOWSHARERC" && \
    process_configfile_module_options 'Plowup' "$MODULE" 'UPLOAD'

for FILE in "$@"; do

    # Check for remote upload
    if match_remote_url "$FILE"; then
        IFS=":" read P1 P2 DESTFILE <<< "$FILE"

        if [ -z "$DESTFILE" ]; then
            LOCALFILE=$(echo "$FILE" | strip | uri_encode)
            DESTFILE='dummy'
        else
            LOCALFILE=$(echo "$P1$P2" | strip | uri_encode)
        fi
    else
        # non greedy parsing
        IFS=":" read LOCALFILE DESTFILE <<< "$FILE"

        if [ -d "$LOCALFILE" ]; then
            log_notice "Skipping ($LOCALFILE): directory"
            continue
        fi

        if [ ! -f "$LOCALFILE" ]; then
            log_notice "Skipping ($LOCALFILE): cannot find file"
            continue
        fi

        if [ ! -s "$LOCALFILE" ]; then
            log_notice "Skipping ($LOCALFILE): filesize is null"
            continue
        fi
    fi

    DESTFILE=$(basename_file "${DESTFILE:-$LOCALFILE}")
    test "$NAME_PREFIX" && DESTFILE="${NAME_PREFIX}${DESTFILE}"
    test "$NAME_SUFFIX" && DESTFILE="${DESTFILE}${NAME_SUFFIX}"

    log_notice "Starting upload ($MODULE): $LOCALFILE"
    log_notice "Destination file: $DESTFILE"

    TRY=0
    while true; do
        : > "$UPCOOKIE"
        URETVAL=0
        $FUNCTION "${UNUSED_OPTIONS[@]}" "$UPCOOKIE" "$LOCALFILE" "$DESTFILE" || URETVAL=$?

        (( ++TRY ))
        if [[ "$MAXRETRIES" -eq 0 ]]; then
            break
        elif [ $URETVAL -ne $ERR_FATAL -a $URETVAL -ne $ERR_NETWORK ]; then
            RETVALS=(${RETVALS[@]} "$URETVAL")
            break
        elif [ "$MAXRETRIES" -lt "$TRY" ]; then
            RETVALS=(${RETVALS[@]} "$ERR_MAX_TRIES_REACHED")
            break
        fi

        log_notice "Starting upload ($MODULE): retry ${TRY}/$MAXRETRIES"
    done
done

rm -f "$UPCOOKIE"

if [ ${#RETVALS[@]} -eq 0 ]; then
    exit 0
elif [ ${#RETVALS[@]} -eq 1 ]; then
    exit ${RETVALS[0]}
else
    log_debug "retvals:${RETVALS[@]}"
    exit $((ERR_FATAL_MULTIPLE + ${RETVALS[0]}))
fi
