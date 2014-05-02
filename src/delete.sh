#!/usr/bin/env bash
#
# Delete files from file sharing websites
# Copyright (c) 2010-2013 Plowshare team
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

declare -r EARLY_OPTIONS="
HELP,h,help,,Show help info and exit
HELPFULL,H,longhelp,,Exhaustive help info (with modules command-line options)
GETVERSION,,version,,Output plowdel version information and exit
ALLMODULES,,modules,,Output available modules (one per line) and exit. Useful for wrappers.
EXT_PLOWSHARERC,,plowsharerc,f=FILE,Force using an alternate configuration file (overrides default search path)
NO_PLOWSHARERC,,no-plowsharerc,,Do not use any plowshare.conf configuration file"

declare -r MAIN_OPTIONS="
VERBOSE,v,verbose,V=LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
INTERFACE,i,interface,s=IFACE,Force IFACE network interface
CAPTCHA_METHOD,,captchamethod,s=METHOD,Force specific captcha solving method. Available: online, imgur, x11, fb, nox, none.
CAPTCHA_PROGRAM,,captchaprogram,F=PROGRAM,Call external program/script for captcha solving.
CAPTCHA_9KWEU,,9kweu,s=KEY,9kw.eu captcha (API) key
CAPTCHA_ANTIGATE,,antigate,s=KEY,Antigate.com captcha key
CAPTCHA_BHOOD,,captchabhood,a=USER:PASSWD,CaptchaBrotherhood account
CAPTCHA_DEATHBY,,deathbycaptcha,a=USER:PASSWD,DeathByCaptcha account
ENGINE,,engine,s=ENGINE,Use specific engine (add more modules). Available: xfilesharing."


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
# Note: $MODULES is a multi-line list
usage() {
    echo 'Usage: plowdel [OPTIONS] [MODULE_OPTIONS] URL...'
    echo 'Delete files from file sharing websites links.'
    echo
    echo 'Global options:'
    print_options "$EARLY_OPTIONS$MAIN_OPTIONS"
    test -z "$1" || print_module_options "$MODULES" DELETE
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

set -e # enable exit checking

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'delete') || exit
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Process command-line (plowdel early options)
eval "$(process_core_options 'plowdel' "$EARLY_OPTIONS" "$@")" || exit

test "$HELPFULL" && { usage 1; exit 0; }
test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

if test "$ALLMODULES"; then
    for MODULE in $MODULES; do echo "$MODULE"; done
    exit 0
fi

# Get configuration file options. Command-line is partially parsed.
test -z "$NO_PLOWSHARERC" && \
    process_configfile_options '[Pp]lowdel' "$MAIN_OPTIONS" "$EXT_PLOWSHARERC"

declare -a COMMAND_LINE_MODULE_OPTS COMMAND_LINE_ARGS RETVALS
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}")

# Process command-line (plowdel options).
# Note: Ignore returned UNUSED_ARGS[@], it will be empty.
eval "$(process_core_options 'plowdel' "$MAIN_OPTIONS" "${UNUSED_OPTS[@]}")" || exit

# Verify verbose level
if [ -n "$QUIET" ]; then
    declare -r VERBOSE=0
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

if [ $# -lt 1 ]; then
    log_error 'plowdel: no URL specified!'
    log_error "plowdel: try \`plowdel --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

if [ -n "$EXT_PLOWSHARERC" ]; then
    if [ -n "$NO_PLOWSHARERC" ]; then
        log_notice 'plowdel: --no-plowsharerc selected and prevails over --plowsharerc'
    else
        log_notice 'plowdel: using alternate configuration file'
    fi
fi

if [ -n "$ENGINE" ]; then
    if [ "$ENGINE" = 'xfilesharing' ]; then
        source "$LIBDIR/engine/$ENGINE.sh"
        log_notice "plowdel: initializing $ENGINE engine"
        if ! ${ENGINE}_init "$LIBDIR/engine"; then
            log_error "$ENGINE initialization error"
            exit $ERR_FATAL
        fi
    else
        log_error "Error: unknown engine name: $ENGINE"
        exit $ERR_FATAL
    fi
fi

if [ -n "$CAPTCHA_PROGRAM" ]; then
    log_debug 'plowdel: --captchaprogram selected'
fi

if [ -n "$CAPTCHA_METHOD" ]; then
    captcha_method_translate "$CAPTCHA_METHOD" || exit
    log_notice "plowdel: force captcha method ($CAPTCHA_METHOD)"
else
    [ -n "$CAPTCHA_9KWEU" ] && log_debug 'plowdel: --9kweu selected'
    [ -n "$CAPTCHA_ANTIGATE" ] && log_debug 'plowdel: --antigate selected'
    [ -n "$CAPTCHA_BHOOD" ] && log_debug 'plowdel: --captchabhood selected'
    [ -n "$CAPTCHA_DEATHBY" ] && log_debug 'plowdel: --deathbycaptcha selected'
fi

MODULE_OPTIONS=$(get_all_modules_options "$MODULES" DELETE)

if [ -n "$ENGINE" ]; then
    MODULE_OPTIONS=$MODULE_OPTIONS$'\n'$(${ENGINE}_get_core_options DELETE)
    MODULE_OPTIONS=$MODULE_OPTIONS$'\n'$(${ENGINE}_get_all_modules_options DELETE)
fi

# Process command-line (all module options)
eval "$(process_all_modules_options 'plowdel' "$MODULE_OPTIONS" \
    "${UNUSED_OPTS[@]}")" || exit

# Prepend here to keep command-line order
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}" "${COMMAND_LINE_ARGS[@]}")
COMMAND_LINE_MODULE_OPTS=("${UNUSED_OPTS[@]}")

if [ ${#COMMAND_LINE_ARGS[@]} -eq 0 ]; then
    log_error 'plowdel: no URL specified!'
    log_error "plowdel: try \`plowdel --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

# Sanity check
for MOD in $MODULES; do
    if ! declare -f "${MOD}_delete" > /dev/null; then
        log_error "plowdel: module \`${MOD}_delete' function was not found"
        exit $ERR_BAD_COMMAND_LINE
    fi
done

set_exit_trap

DCOOKIE=$(create_tempfile) || exit

for URL in "${COMMAND_LINE_ARGS[@]}"; do
    DRETVAL=0

    MODULE=$(get_module "$URL" "$MODULES") || DRETVAL=$?

    if [ $DRETVAL -ne 0 ] && [ -n "$ENGINE" ] && match_remote_url "$URL"; then
        DRETVAL=0
        if ${ENGINE}_probe_module 'plowdel' "$URL"; then
            MODULE=$(${ENGINE}_get_module "$URL") || DRETVAL=$?
        else
            DRETVAL=$ERR_NOMODULE
        fi
    fi

    if [ $DRETVAL -ne 0 ]; then
        if ! match_remote_url "$URL"; then
            log_error "Skip: not an URL ($URL)"
        else
            log_error "Skip: no module for URL ($(basename_url "$URL")/)"
        fi
        RETVALS=(${RETVALS[@]} $DRETVAL)
        continue
    fi

    # Get configuration file module options
    test -z "$NO_PLOWSHARERC" && \
        process_configfile_module_options '[Pp]lowdel' "$MODULE" DELETE "$EXT_PLOWSHARERC"

    [ -n "$ENGINE" ] && \
        eval "$(process_engine_options "$ENGINE" \
            "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

    eval "$(process_module_options "${MODULE//:/_}" DELETE \
        "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

    FUNCTION=${MODULE}_delete
    log_notice "Starting delete ($MODULE): $URL"

    :> "$DCOOKIE"

    [ -n "$ENGINE" ] && ${ENGINE}_vars_set
    ${MODULE//:/_}_vars_set

    $FUNCTION "${UNUSED_OPTIONS[@]}" "$DCOOKIE" "$URL" || DRETVAL=$?

    [ -n "$ENGINE" ] && ${ENGINE}_vars_unset
    ${MODULE//:/_}_vars_unset

    if [ $DRETVAL -eq 0 ]; then
        log_notice 'File removed successfully'
    elif [ $DRETVAL -eq $ERR_LINK_NEED_PERMISSIONS ]; then
        log_error 'Anonymous users cannot delete links'
    elif [ $DRETVAL -eq $ERR_LINK_DEAD ]; then
        log_error 'Not found or already deleted'
    elif [ $DRETVAL -eq $ERR_LOGIN_FAILED ]; then
        log_error 'Login process failed. Bad username/password or unexpected content'
    else
        log_error "Failed inside ${FUNCTION}() [$DRETVAL]"
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
