#!/usr/bin/env bash
#
# Easy module management (installation/update) utility
# Copyright (c) 2015 Plowshare team
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

declare -r VERSION='GIT-snapshot'

# Default repository source
declare -r LEGACY_MODULES='https://github.com/mcrapet/plowshare-modules-legacy.git'

declare -r MAIN_OPTIONS="
HELP,h,help,,Show help info and exit
GETVERSION,,version,,Output plowmod version information and exit
VERBOSE,v,verbose,c|0|1|2|3|4=LEVEL,Verbosity level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
NO_COLOR,,no-color,,Disables log notice & log error output coloring
MOD_DIR,,modules-directory,D=DIR,For maintainers only. Set modules directory (default is ~/.config/plowshare/modules.d)"
declare -r ACTION_OPTIONS="
DO_INSTALL,i,install,,Install one or several given repositories to modules directory
DO_STATUS,s,status,,Print current modules configuration
DO_UPDATE,u,update,,Update modules directory (requires git)"

# This function is duplicated from download.sh
absolute_path() {
    local SAVED_PWD=$PWD
    local TARGET=$1

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
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

# Print usage (on stdout)
usage() {
    cat <<EOH
Usage: plowmod ACTION [OPTIONS] [URL]...
Easy plowshare modules management.

Possible actions:
EOH
    print_options "$ACTION_OPTIONS"
    cat <<EOH

For install, if no source repository is specified use:
$LEGACY_MODULES

Available options:
EOH
    print_options "$MAIN_OPTIONS"
}

# Compute modules.d/NAME from URL
get_dir_name() {
    local n=$1
    n=$(basename_file "${n%/}")
    if [[ $n =~ ([Pp]lowshare[-._])([Mm]odules?[-._])?([^/?#]*) ]] ; then
        echo "${BASH_REMATCH[3]}"
    else
        echo "$n"
    fi
}

# Install a new repository or archive file
# $1: local modules directory path
# $2: repository URL (file:// is accepted)
mod_install() {
    local L=$1
    local R=$2
    local RET=0

    log_notice "- installing new directory: $L"

    if [ -d "$L" -a -n "$HAVE_GIT" ]; then
        if git -C "$L" rev-parse --is-inside-work-tree &>/dev/null; then
            log_notice 'WARNING: directory already exists! Do a git pull.'
            git -C "$L" pull --quiet
        else
            log_error 'ERROR: directory exists but it does not appear to be a git repository, abort'
            RET=$ERR_FATAL
        fi
    else
        # Be stupid for now and git clone. See --depth later.
        git clone --quiet "$R" "$L"
    fi
    return $RET
}

# Install a new repository
# $1: local modules directory path
# $2: repository URL or empty string (will detect .git)
mod_update() {
    local L=$1
    local RET=0

    log_notice "- updating directory: $L"

    if [ -d "$L" ]; then
        if [ -n "$HAVE_GIT" ]; then
            if git -C "$L" rev-parse --is-inside-work-tree &>/dev/null; then
                git -C "$L" pull --quiet
            else
                log_error 'ERROR: directory exists but it does not appear to be a git repository, abort!'
                RET=$ERR_FATAL
            fi
        else
            log_error 'ERROR: git is not installed, abort'
            RET=$ERR_SYSTEM
        fi
    else
        log_error 'ERROR: directory does not exists, abort'
        RET=$ERR_FATAL
    fi
    return $RET
}

# Information about modules location
# $1: System modules path
# $2: User modules or modules.d path
mod_status() {
    local -a SRCS
    local -A MLIST DLIST
    local -i N
    local D CONFIG

    if [ -d "$1/modules" -a -f "$1/modules/config" ]; then
        SRCS+=( "$1/modules" )
    fi

    if [ "${2%/modules.d}" = "$2" -a -f "$2/config" ]; then
        SRCS+=( "$2" )
    else
        if [ "${2%.d}" -a -f "${2%.d}/config" ]; then
            SRCS+=( "${2%.d}" )
        fi
        while read -r; do
            D=$(dirname "$REPLY")
            SRCS+=( "$D" )
        done < <(find "$2" -mindepth 2 -maxdepth 2 -name config)
    fi

    # Check for first install
    N=$(grep '^[^#]' "${SRCS[@]/%/\/config}" | wc -l)
    if (( N == 0 )); then
        log_error \
"-------------------------------------------------------------------------------
Your plowshare installation has currently no module.
($2/ is empty)

In order to use plowdown you must install some modules. Here is a quick start:
$ plowmod --install
-------------------------------------------------------------------------------"
        return $ERR_NOMODULE
    fi

    log_notice 'Found modules locations:'
    for D in "${SRCS[@]}"; do
        N=$(grep -c '^[^#]' "$D/config")
        if [ $N -eq 0 ]; then
            log_notice "- $D (no module detected)"
        elif [ $N -eq 1 ]; then
            log_notice "- $D ($N module found)"
        else
            log_notice "- $D ($N modules found)"
        fi
    done

    N=0
    for D in "${SRCS[@]}"; do
        CONFIG="$D/config"
        if [[ -d "$D" && -f "$CONFIG" ]]; then
            while read -r; do
                if [ -f "$D/$REPLY.sh" ]; then
                    if [[ ${MLIST["$REPLY"]} ]]; then
                        if [[ ! ${DLIST["$D"]} ]]; then
                            DLIST["$D"]=$(dirname ${MLIST["$REPLY"]})
                        fi
                        (( ++N ))
                    else
                        MLIST[$REPLY]="$D/$REPLY.sh"
                    fi
                else
                    log_error "$CONFIG: \`$REPLY\` module not found, ignoring"
                fi
            done < <(sed -ne "/^[^#]/s/^\([^[:space:]|]*\).*/\1/p" "$CONFIG")
        fi
    done
    if (( N == 0 )); then
        log_debug 'Modules directories overrides: no conflict detected!'
    else
        log_debug "Modules directories overrides: $N modules conflicts detected!"
        for D in "${!DLIST[@]}"; do
            log_debug "$D conflicts with ${DLIST["$D"]}"
        done
    fi

    return 0
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")
readonly LIBDIR
TMPDIR=${TMPDIR:-/tmp}

set -e # enable exit checking

source "$LIBDIR/core.sh"

# Process command-line (plowmod options).
# Note: Ignore returned UNUSED_ARGS[@], it will be empty.
eval "$(process_core_options 'plowmod' "$MAIN_OPTIONS$ACTION_OPTIONS" "$@")" || exit

test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

if [ -n "$NO_COLOR" ]; then
    unset COLOR
else
    declare -r COLOR=yes
fi

# Verify verbose level
if [ -n "$QUIET" ]; then
    if [ -z "$VERBOSE" ]; then
        declare -r VERBOSE=0
    else
        log_notice "WARNING: --quiet switch conflicts with --verbose=$VERBOSE, ignoring -q"
    fi
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

declare -a ARGS=("${UNUSED_OPTS[@]}")

if [ -z "$DO_INSTALL" -a -z "$DO_UPDATE" -a -z "$DO_STATUS" ]; then
    log_error 'plowmod: no action specified!'
    log_error "plowmod: try \`plowmod --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
elif [ -n "$DO_INSTALL" -a -n "$DO_UPDATE" ]; then
    log_error 'plowmod: --install and --update are conflicting actions. You must choose only one.'
    exit $ERR_BAD_COMMAND_LINE
elif [ -z "$DO_INSTALL" -a "${#ARGS[@]}" -gt 0 ]; then
    # No argument for update or status
    log_notice "plowmod: two much arguments given, ignoring \`${ARGS[*]}'"
elif [ -n "$DO_INSTALL" ]; then
    # Check provided repositories
    REPOS=()
    for U in "${ARGS[@]}"; do
        if match_remote_url "$U"; then
            REPOS+=("$U")
        else
            log_notice "plowmod: invalid URL \`$U', ignoring"
        fi
    done
    if [ "${#ARGS[@]}" -le 0 ]; then
        log_notice "plowmod: adding legacy (default) repository: $LEGACY_MODULES"
        REPOS+=("$LEGACY_MODULES")
    elif [ "${#REPOS[@]}" -le 0 ]; then
        log_error "plowmod: no valid URL given. Maybe just try \`plowup -i' for default installation."
    fi
fi

# Check modules directory
if [ -z "$MOD_DIR" ]; then
    DDIR="$PLOWSHARE_CONFDIR/modules.d"
else
    DDIR=${MOD_DIR%/}
fi
log_debug "modules directory: $DDIR"

[ -d "$DDIR" ] || mkdir -p "$DDIR"
if [ ! -w "$DDIR" ]; then
    log_error 'ERROR: Modules directory is not writable, abort.'
    exit $ERR_BAD_COMMAND_LINE
fi

if check_exec 'git'; then
    HAVE_GIT=1
    log_report "[git ] $(git --version)"
fi

set_exit_trap

declare -a RETVALS

if [ -n "$DO_INSTALL" ]; then
    for U in "${REPOS[@]}"; do
        RETVAL=0
        DDIR="$DDIR/$(get_dir_name "$U")"
        mod_install "$DDIR" "$U" || RETVAL=$?
        RETVALS+=($RETVAL)
    done
elif [ -n "$DO_STATUS" ]; then
    RETVAL=0
    mod_status "$LIBDIR" "$DDIR" || RETVAL=$?
    RETVALS+=($RETVAL)
elif [ -n "$DO_UPDATE" ]; then
    while read -r; do
        RETVAL=0
        U=$(dirname "$REPLY")
        mod_update "$U" || RETVAL=$?
        RETVALS+=($RETVAL)
    done < <(find "$DDIR" -mindepth 2 -maxdepth 2 -name config)
fi

if [ ${#RETVALS[@]} -eq 0 ]; then
    exit 0
elif [ ${#RETVALS[@]} -eq 1 ]; then
    exit ${RETVALS[0]}
else
    log_debug "retvals:${RETVALS[*]}"
    # Drop success values
    RETVALS=(${RETVALS[@]/#0*} -$ERR_FATAL_MULTIPLE)

    exit $((ERR_FATAL_MULTIPLE + ${RETVALS[0]}))
fi
