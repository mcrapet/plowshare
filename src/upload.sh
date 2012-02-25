#!/bin/bash -e
#
# Upload a file to file sharing servers
# Copyright (c) 2010-2012 Plowshare team
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
MAX_LIMIT_RATE,,max-rate:,SPEED,Limit maximum speed to bytes/sec (suffixes: k=Kb, m=Mb, g=Gb)
MIN_LIMIT_RATE,,min-rate:,SPEED,Limit minimum speed to bytes/sec (during 30 seconds)
INTERFACE,i:,interface:,IFACE,Force IFACE network interface
MAXRETRIES,r:,max-retries:,N,Set maximum retries for upload failures. 0 means no retry (default).
NAME_PREFIX,,name-prefix:,STRING,Prepend argument to each destination filename
NAME_SUFFIX,,name-suffix:,STRING,Append argument to each destination filename
PRINTF_FORMAT,,printf:,FORMAT,Print results in a given format (for each upload). Default string is: \"%u (%D)\".
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

# Convert to byte value. Does not deal with floating notation.
# $1: rate with optional suffix (example: "50K")
# stdout: number
parse_rate() {
    local N="${1//[^0-9]}"
    if test "${1:(-1):1}" = "K"; then
        echo $((N * 1000))
    elif test "${1:(-1):1}" = "k"; then
        echo $((N * 1024))
    else
        echo $((N))
    fi
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
    local N=$(lowercase "$2")
    while read MODULE; do
        if test "$N" = "$MODULE"; then
            echo "$N"
            return 0
        fi
    done <<< "$1"
    return 1
}

# Example: "MODULE_ZSHARE_UPLOAD_REMOTE_SUPPORT=no"
# $1: module name
module_config_remote_upload() {
    local VAR="MODULE_$(uppercase "$1")_UPLOAD_REMOTE_SUPPORT"
    test "${!VAR}" = 'yes'
}

# Plowup printf format
# ---
# Interpreted sequences are:
# %f: destination (remote) filename
# %u: download url
# %d: delete url
# %a: admin url or admin code
# %m: module name
# %s: filesize (in bytes)
# %D: %d or %a (if %d is empty)
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
    S=${1//%[fudamsDnt%]}
    TOKEN=$(parse_quiet . '\(%.\)' <<<"$S")
    if [ -n "$TOKEN" ]; then
        log_error "Bad format string: unknown sequence << $TOKEN >>"
        return $ERR_FATAL
    fi
}

# Note: don't use printf (coreutils).
# $1: array[@] (module, lfile, dfile, dl, del, adm)
# $2: format string
pretty_print() {
    local -a A=("${!1}")
    local FMT=$2

    test "${FMT#*%m}" != "$FMT" && FMT=$(replace '%m' "${A[0]}" <<< "$FMT")
    test "${FMT#*%s}" != "$FMT" && \
         FMT=$(replace '%s' $(get_filesize "${A[1]}") <<< "$FMT")
    test "${FMT#*%f}" != "$FMT" && FMT=$(replace '%f' "${A[2]}" <<< "$FMT")
    test "${FMT#*%u}" != "$FMT" && FMT=$(replace '%u' "${A[3]}" <<< "$FMT")
    test "${FMT#*%d}" != "$FMT" && FMT=$(replace '%d' "${A[4]}" <<< "$FMT")
    test "${FMT#*%a}" != "$FMT" && FMT=$(replace '%a' "${A[5]}" <<< "$FMT")
    test "${FMT#*%D}" != "$FMT" && \
        FMT=$(replace '%D' "${A[4]:-${A[5]}}" <<< "$FMT")
    test "${FMT#*%n}" != "$FMT" && FMT=$(replace '%n' $'\n' <<< "$FMT")
    test "${FMT#*%t}" != "$FMT" && FMT=$(replace '%t' '	'   <<< "$FMT")
    test "${FMT#*%%}" != "$FMT" && FMT=$(replace '%%' '%'   <<< "$FMT")

    echo "$FMT"
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'upload') || exit
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Get configuration file options. Command-line is not parsed yet.
match '--no-plowsharerc' "$*" || \
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

# Get configuration file module options
test -z "$NO_PLOWSHARERC" && \
    process_configfile_module_options 'Plowup' "$MODULE" 'UPLOAD'

# Curl minimal rate (--speed-limit) does not support suffixes
if [ -n "$MIN_LIMIT_RATE" ]; then
    MIN_LIMIT_RATE=$(parse_rate "$MIN_LIMIT_RATE")
fi

if [ -n "$PRINTF_FORMAT" ]; then
    pretty_check "$PRINTF_FORMAT" || exit
fi

# Remove module name from argument list
shift 1

set_exit_trap

UCOOKIE=$(create_tempfile) || exit
URESULT=$(create_tempfile) || exit
FUNCTION=${MODULE}_upload

RETVALS=()
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

        if ! module_config_remote_upload "$MODULE"; then
            log_notice "Skipping ($LOCALFILE): remote upload is not supported"
            continue
        fi

        # Check if URL is alive
        CODE=$(curl --head -L -w '%{http_code}' "$LOCALFILE" | last_line) || true
        if [ "${CODE:0:1}" = 4 -o "${CODE:0:1}" = 5 ]; then
            log_notice "Skipping ($LOCALFILE): cannt access link (HTTP status $CODE)"
            continue
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

    if match '[;,]' "$DESTFILE"; then
        log_notice "Skipping ($LOCALFILE): curl can't upload filenames that contain , or ;"
        continue
    fi

    test "$NAME_PREFIX" && DESTFILE="${NAME_PREFIX}${DESTFILE}"
    test "$NAME_SUFFIX" && DESTFILE="${DESTFILE}${NAME_SUFFIX}"

    log_notice "Starting upload ($MODULE): $LOCALFILE"
    log_notice "Destination file: $DESTFILE"

    TRY=0
    while :; do
        :> "$UCOOKIE"
        URETVAL=0
        $FUNCTION "${UNUSED_OPTIONS[@]}" "$UCOOKIE" "$LOCALFILE" "$DESTFILE" >"$URESULT" || URETVAL=$?

        (( ++TRY ))
        if [[ $MAXRETRIES -eq 0 ]]; then
            break
        elif [ $URETVAL -ne $ERR_FATAL -a $URETVAL -ne $ERR_NETWORK ]; then
            break
        elif [ "$MAXRETRIES" -lt "$TRY" ]; then
            URETVAL=$ERR_MAX_TRIES_REACHED
            break
        fi

        log_notice "Starting upload ($MODULE): retry ${TRY}/$MAXRETRIES"
    done

    if [ $URETVAL -eq 0 ]; then
        { read DL_URL; read DEL_URL; read ADMIN_URL_OR_CODE; } <"$URESULT" || true
        if [ -n "$DL_URL" ]; then
            DATA=("$MODULE" "$LOCALFILE" "$DESTFILE" \
                  "$DL_URL" "$DEL_URL" "$ADMIN_URL_OR_CODE")
            pretty_print DATA[@] "${PRINTF_FORMAT:-%u (%D)}"
        else
            log_error "Output URL expected"
            URETVAL=$ERR_FATAL
        fi
    elif [ $URETVAL -eq $ERR_LOGIN_FAILED ]; then
        log_error "Login process failed. Bad username/password or unexpected content"
    fi
    RETVALS=(${RETVALS[@]} $URETVAL)
done

rm -f "$UCOOKIE" "$URESULT"

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
