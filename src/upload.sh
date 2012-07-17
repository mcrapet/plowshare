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
HELPFULL,H,longhelp,,Exhaustive help info (with modules command-line options)
GETVERSION,,version,,Return plowup version
VERBOSE,v,verbose,V=LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
MAX_LIMIT_RATE,,max-rate,n=SPEED,Limit maximum speed to bytes/sec (suffixes: k=kB, m=MB, g=GB)
MIN_LIMIT_RATE,,min-rate,n=SPEED,Limit minimum speed to bytes/sec (during 30 seconds)
INTERFACE,i,interface,s=IFACE,Force IFACE network interface
TIMEOUT,t,timeout,n=SECS,Timeout after SECS seconds of waits
MAXRETRIES,r,max-retries,N=NUM,Set maximum retries for upload failures (fatal, network errors). Default is 0 (no retry).
NAME_PREFIX,,name-prefix,s=STRING,Prepend argument to each destination filename
NAME_SUFFIX,,name-suffix,s=STRING,Append argument to each destination filename
PRINTF_FORMAT,,printf,s=FORMAT,Print results in a given format (for each upload). Default string is: \"%u (%D)\".
NO_CURLRC,,no-curlrc,,Do not use curlrc config file
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

# Convert to byte value. Does not deal with floating notation.
# $1: rate with optional suffix (example: "50K")
# stdout: number
parse_rate() {
    local N="${1//[^0-9]}"
    if test "${1:(-1):1}" = "K"; then
        echo $((N * 1024))
    elif test "${1:(-1):1}" = "k"; then
        echo $((N * 1000))
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
    print_options "$OPTIONS"
    test -z "$1" || print_module_options "$MODULES" UPLOAD
}

# Check if module name is contained in list
#
# $1: module name list (one per line)
# $2: module name
# $?: zero for found, non zero otherwie
# stdout: lowercase module name (if found)
module_exist() {
    local N1=$(lowercase "$2")
    local N2=${N1//./_}
    local MODULE

    while read MODULE; do
        if [[ $N1 = $MODULE || $N2 = $MODULE ]]; then
            echo "$MODULE"
            return 0
        fi
    done <<< "$1"
    return 1
}

# Example: "MODULE_4SHARED_UPLOAD_REMOTE_SUPPORT=no"
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
    test "${FMT#*%t}" != "$FMT" && FMT=$(replace '%t' '	' <<< "$FMT")
    test "${FMT#*%%}" != "$FMT" && FMT=$(replace '%%' '%' <<< "$FMT")

    if test "${FMT#*%n}" != "$FMT"; then
        # Don't lose trailing newlines
        FMT=$(replace '%n' $'\n' <<< "$FMT" ; echo -n x)
        echo -n "${FMT%x}"
    else
        echo "$FMT"
    fi
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

# Process plowup options
eval "$(process_core_options1 'plowup' "$OPTIONS" \
    "$@")" || exit $ERR_BAD_COMMAND_LINE

# Verify verbose level
if [ -n "$QUIET" ]; then
    declare -r VERBOSE=0
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

test "$HELPFULL" && { usage 1; exit 0; }
test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

if [ $# -lt 1 ]; then
    log_error "plowup: no module specified!"
    log_error "plowup: try \`plowup --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

log_report_info
log_report "plowup version $VERSION"

# Get configuration file module options
test -z "$NO_PLOWSHARERC" && \
    process_configfile_module_options 'Plowup' "$MODULE" UPLOAD

# Curl minimal rate (--speed-limit) does not support suffixes
if [ -n "$MIN_LIMIT_RATE" ]; then
    MIN_LIMIT_RATE=$(parse_rate "$MIN_LIMIT_RATE")
fi

if [ -n "$PRINTF_FORMAT" ]; then
    pretty_check "$PRINTF_FORMAT" || exit
fi

if [ -z "$NO_CURLRC" -a -f "$HOME/.curlrc" ]; then
    log_debug "using local ~/.curlrc"
fi

declare -a COMMAND_LINE_MODULE_OPTS COMMAND_LINE_ARGS RETVALS

MODULE_OPTIONS=$(get_all_modules_options "$MODULES" UPLOAD)
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}")

# Process module options
eval "$(process_core_options2 'plowup' "$MODULE_OPTIONS" \
    "${UNUSED_OPTS[@]}")" || exit $ERR_BAD_COMMAND_LINE

COMMAND_LINE_ARGS=("${COMMAND_LINE_ARGS[@]}" "${UNUSED_ARGS[@]}")
COMMAND_LINE_MODULE_OPTS=("${UNUSED_OPTS[@]}")

if [ ${#COMMAND_LINE_ARGS[@]} -eq 0 ]; then
    log_error "plowup: no module specified!"
    log_error "plowup: try \`plowup --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

# Check requested module
MODULE=$(module_exist "$MODULES" "${COMMAND_LINE_ARGS[0]}") || {
    log_error "plowup: unsupported module ($1)";
    exit $ERR_NOMODULE;
}

if [ ${#COMMAND_LINE_ARGS[@]} -lt 2 ]; then
    log_error "plowup: you must specify a filename."
    log_error "plowup: try \`plowup --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

# Remove module name from argument list
unset COMMAND_LINE_ARGS[0]

set_exit_trap

UCOOKIE=$(create_tempfile) || exit
URESULT=$(create_tempfile) || exit
FUNCTION=${MODULE}_upload

for FILE in "${COMMAND_LINE_ARGS[@]}"; do

    # Check for remote upload
    if match_remote_url "$FILE"; then
        DESTFILE=${FILE##*:}
        if [ "$DESTFILE" = "${DESTFILE/\/}" ]; then
            LOCALFILE=$(echo  "${FILE%:*}" | strip | uri_encode)
        else
            LOCALFILE=$(echo "$FILE" | strip | uri_encode)
            DESTFILE='dummy'
        fi

        if ! module_config_remote_upload "$MODULE"; then
            log_notice "Skipping ($LOCALFILE): remote upload is not supported"
            RETVALS=(${RETVALS[@]} $ERR_BAD_COMMAND_LINE)
            continue
        fi

        # Check if URL is alive
        CODE=$(curl --head -L -w '%{http_code}' "$LOCALFILE" | last_line) || {
            log_notice "Skipping ($LOCALFILE)";
            continue;
        }
        if [[ $CODE = [45]* ]]; then
            log_notice "Skipping ($LOCALFILE): cannot access link (HTTP status $CODE)"
            continue
        fi
    else
        # Non greedy parsing
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

    timeout_init $TIMEOUT

    eval "$(process_module_options "$MODULE" UPLOAD \
        "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

    TRY=0
    "${MODULE}_vars_set"

    while :; do
        :> "$UCOOKIE"
        URETVAL=0
        $FUNCTION "$UCOOKIE" "$LOCALFILE" \
            "$DESTFILE" >"$URESULT" || URETVAL=$?

        if [ $URETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
            read AWAIT <"$URESULT" || true
            if [ -z "$AWAIT" ]; then
                log_debug "arbitrary wait"
            else
                log_debug "arbitrary wait (from module)"
            fi
            wait ${AWAIT:-60} || { URETVAL=$?; break; }
        elif [[ $MAXRETRIES -eq 0 ]]; then
            break
        elif [ $URETVAL -ne $ERR_FATAL -a $URETVAL -ne $ERR_NETWORK ]; then
            break
        elif (( MAXRETRIES < ++TRY )); then
            URETVAL=$ERR_MAX_TRIES_REACHED
            break
        fi

        log_notice "Starting upload ($MODULE): retry $TRY/$MAXRETRIES"
    done

    "${MODULE}_vars_unset"

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
    elif [ $URETVAL -eq $ERR_LINK_NEED_PERMISSIONS ]; then
        log_error "Anonymous users cannot upload files"
    elif [ $URETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
        log_error "Upload feature seems disabled from upstream now"
    elif [ $URETVAL -eq $ERR_LOGIN_FAILED ]; then
        log_error "Login process failed. Bad username/password or unexpected content"
    elif [ $URETVAL -eq $ERR_SIZE_LIMIT_EXCEEDED ]; then
        log_error "Insufficient permissions (file size limit exceeded)"
    elif [ $URETVAL -eq $ERR_MAX_TRIES_REACHED ]; then
        log_error "Retry limit reached (max=$MAXRETRIES)"
    elif [ $URETVAL -eq $ERR_BAD_COMMAND_LINE ]; then
        log_error "Wrong module option, check your command line"
    else
        log_error "Failed inside ${FUNCTION}() [$URETVAL]"
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
