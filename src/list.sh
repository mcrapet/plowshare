#!/bin/bash -e
#
# Retrieve list of links from a shared-folder (sharing site) url
# Copyright (c) 2010-2012 Plowshare team
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


VERSION="GIT-snapshot"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,,version,,Return plowlist version
VERBOSE,v,verbose,V=LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
INTERFACE,i,interface,s=IFACE,Force IFACE network interface
RECURSE,R,recursive,,Recurse into sub folders
PRINTF_FORMAT,,printf,s=FORMAT,Print results in a given format (for each link). Default string is: \"%F%u\".
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
    echo 'Usage: plowlist [OPTIONS] [MODULE_OPTIONS] URL...'
    echo
    echo '  Retrieve list of links from a shared-folder (sharing site) url.'
    echo '  Available modules:' $MODULES
    echo
    echo 'Global options:'
    echo
    print_options "$OPTIONS"
    print_module_options "$MODULES" LIST
}

# Plowlist printf format
# ---
# Interpreted sequences are:
# %f: filename (can be an empty string)
# %F: alias for "# %f%n" or empty string if %f is empty
# %u: download url
# %m: module name
# and also:
# %n: newline
# %t: tabulation
# %%: raw %
# ---
#
# Check user given format
# $1: format string
pretty_check() {
    # This must be non greedy!
    local S TOKEN
    S=${1//%[fFumnt%]}
    TOKEN=$(parse_quiet . '\(%.\)' <<<"$S")
    if [ -n "$TOKEN" ]; then
        log_error "Bad format string: unknown sequence << $TOKEN >>"
        return $ERR_FATAL
    fi
}

# Note: don't use printf (coreutils).
# $1: format string
# $2: module name
pretty_print() {
    local FMT=$1
    local CR=$'\n'
    local URL NAME S

    test "${FMT#*%m}" != "$FMT" && FMT=$(replace '%m' "$2" <<< "$FMT")
    test "${FMT#*%t}" != "$FMT" && FMT=$(replace '%t' '	' <<< "$FMT")
    test "${FMT#*%%}" != "$FMT" && FMT=$(replace '%%' '%' <<< "$FMT")

    # Pair every two lines
    while IFS= read -r URL; do
        IFS= read -r NAME

        if test "${FMT#*%F}" != "$FMT"; then
            if test "$NAME"; then
                S=$(replace '%F' "# %f%n" <<< "$FMT")
            else
                S=${FMT//%F/}
                [ -z "$S" ] && continue
            fi
        else
            S=$FMT
        fi

        # Don't lose trailing newlines
        if test "${FMT#*%[nF]}" != "$FMT"; then
            S=$(replace '%n' "$CR" <<< "$S" ; echo -n x)
        else
            S="${S}${CR}x"
        fi

        # Special case: $NAME contains '%u'
        if [[ "$NAME" = *%u* ]]; then
            log_notice "$FUNCNAME: replacement error (%u not expected in name)"
            NAME=${NAME//%u/%(u)}
        fi
        test "${FMT#*%[fF]}" != "$FMT" && S=$(replace '%f' "$NAME" <<< "$S")
        test "${FMT#*%u}" != "$FMT" && S=$(replace '%u' "$URL" <<< "$S")

        echo -n "${S%x}"
    done
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'list') || exit
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Get configuration file options. Command-line is not parsed yet.
match '--no-plowsharerc' "$*" || \
    process_configfile_options 'Plowlist' "$OPTIONS"

# Process plowup options
eval "$(process_core_options 'plowlist' "$OPTIONS" \
    "$@")" || exit $ERR_BAD_COMMAND_LINE

# Verify verbose level
if [ -n "$QUIET" ]; then
    declare -r VERBOSE=0
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

if [ $# -lt 1 ]; then
    log_error "plowlist: no URL specified!"
    log_error "plowlist: try \`plowlist --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

if [ -n "$PRINTF_FORMAT" ]; then
    pretty_check "$PRINTF_FORMAT" || exit
fi

# Print chosen options
[ -n "$RECURSE" ] && log_debug "plowlist: --recursive selected"

if [ $# -lt 1 ]; then
    log_error "plowlist: no folder URL specified!"
    log_error "plowlist: try \`plowlist --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

declare -a COMMAND_LINE_MODULE_OPTS COMMAND_LINE_ARGS RETVALS

MODULE_OPTIONS=$(get_all_modules_options "$MODULES" LIST)
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}")

# Process modules options
eval "$(process_all_modules_options 'plowlist' "$MODULE_OPTIONS" \
    "${UNUSED_OPTS[@]}")" || exit $ERR_BAD_COMMAND_LINE

COMMAND_LINE_ARGS=("${COMMAND_LINE_ARGS[@]}" "${UNUSED_ARGS[@]}")
COMMAND_LINE_MODULE_OPTS=("${UNUSED_OPTS[@]}")

if [ ${#COMMAND_LINE_ARGS[@]} -eq 0 ]; then
    log_error "plowlist: no folder URL specified!"
    log_error "plowlist: try \`plowlist --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

set_exit_trap

for URL in "${COMMAND_LINE_ARGS[@]}"; do

    MODULE=$(get_module "$URL" "$MODULES")
    if test -z "$MODULE"; then
        log_error "Skip: no module for URL ($URL)"
        RETVALS=(${RETVALS[@]} $ERR_NOMODULE)
        continue
    fi

    # Get configuration file module options
    test -z "$NO_PLOWSHARERC" && \
        process_configfile_module_options 'Plowlist' "$MODULE" LIST

    eval "$(process_module_options "$MODULE" LIST \
        "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

    FUNCTION=${MODULE}_list
    log_notice "Retrieving list ($MODULE): $URL"

    LRETVAL=0

    "${MODULE}_vars_set"
    $FUNCTION "${UNUSED_OPTIONS[@]}" "$URL" "$RECURSE" | \
        pretty_print "${PRINTF_FORMAT:-%F%u}" "$MODULE" || LRETVAL=$?
    "${MODULE}_vars_unset"

    if [ $LRETVAL -eq 0 ]; then
        : # everything went fine
    elif [ $LRETVAL -eq $ERR_LINK_DEAD ]; then
        log_error "Non existing or empty folder"
        [ -z "$RECURSE" ] && \
            log_notice "Try adding -R/--recursive option to look into sub folders"
    elif [ $LRETVAL -eq $ERR_LINK_PASSWORD_REQUIRED ]; then
        log_error "You must provide a valid password"
    elif [ $LRETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
        log_error "Links are temporarily unavailable. Maybe uploads are still being processed"
    else
        log_error "Failed inside ${FUNCTION}() [$LRETVAL]"
    fi
    RETVALS=(${RETVALS[@]} $LRETVAL)
done

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
