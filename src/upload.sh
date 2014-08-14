#!/usr/bin/env bash
#
# Upload files to file sharing websites
# Copyright (c) 2010-2014 Plowshare team
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
GETVERSION,,version,,Output plowup version information and exit
ALLMODULES,,modules,,Output available modules (one per line) and exit. Useful for wrappers.
EXT_PLOWSHARERC,,plowsharerc,f=FILE,Force using an alternate configuration file (overrides default search path)
NO_PLOWSHARERC,,no-plowsharerc,,Do not use any plowshare.conf configuration file"

declare -r MAIN_OPTIONS="
VERBOSE,v,verbose,c|0|1|2|3|4=LEVEL,Verbosity level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
MAX_LIMIT_RATE,,max-rate,r=SPEED,Limit maximum speed to bytes/sec (accept usual suffixes)
MIN_LIMIT_RATE,,min-rate,r=SPEED,Limit minimum speed to bytes/sec (during 30 seconds)
INTERFACE,i,interface,s=IFACE,Force IFACE network interface
TIMEOUT,t,timeout,n=SECS,Timeout after SECS seconds of waits
MAXRETRIES,r,max-retries,N=NUM,Set maximum retries for upload failures (fatal, network errors). Default is 0 (no retry).
NAME_FORMAT,,name,s=FORMAT,Format destination filename (applies on each file argument). Default string is: \"%f\".
CACHE,,cache,C|none|session|shared=METHOD,Policy for storage data. Available: none, session (default), shared.
CAPTCHA_METHOD,,captchamethod,s=METHOD,Force specific captcha solving method. Available: online, imgur, x11, fb, nox, none.
CAPTCHA_PROGRAM,,captchaprogram,F=PROGRAM,Call external program/script for captcha solving.
CAPTCHA_9KWEU,,9kweu,s=KEY,9kw.eu captcha (API) key
CAPTCHA_ANTIGATE,,antigate,s=KEY,Antigate.com captcha key
CAPTCHA_BHOOD,,captchabhood,a=USER:PASSWD,CaptchaBrotherhood account
CAPTCHA_COIN,,captchacoin,s=KEY,captchacoin.com API key
CAPTCHA_DEATHBY,,deathbycaptcha,a=USER:PASSWD,DeathByCaptcha account
PRINTF_FORMAT,,printf,s=FORMAT,Print results in a given format (for each successful upload). Default string is: \"%D%A%u%n\".
TEMP_DIR,,temp-directory,D=DIR,Directory for temporary files (cookies, images)
NO_CURLRC,,no-curlrc,,Do not use curlrc config file"


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
# Note: Global array variable MODULES is accessed directly.
usage() {
    echo 'Usage: plowup [OPTIONS] MODULE [MODULE_OPTIONS] URL|FILE[:DESTNAME]...'
    echo 'Upload files to file sharing websites.'
    echo
    echo 'Global options:'
    print_options "$EARLY_OPTIONS$MAIN_OPTIONS"
    test -z "$1" || print_module_options MODULES[@] UPLOAD
}

# Check if module name is contained in list
#
# $1: module list (array name)
# $2: module name
# $?: zero for found, non zero otherwie
# stdout: lowercase module name (if found)
module_exist() {
    local N1=${2,,}
    local N2=${N1//./_}
    local MODULE

    for MODULE in "${!1}"; do
        if [[ $N1 = $MODULE || $N2 = $MODULE ]]; then
            echo "$MODULE"
            return 0
        fi
    done
    return 1
}

# Example: "MODULE_4SHARED_UPLOAD_REMOTE_SUPPORT=no"
# $1: module name
module_config_remote_upload() {
    local -u VAR="MODULE_${1}_UPLOAD_REMOTE_SUPPORT"
    [[ ${!VAR} = [Yy][Ee][Ss] || ${!VAR} = 1 ]]
}

# Plowup printf format
# ---
# Interpreted sequences are:
# %f: destination (remote) filename
# %u: download url
# %d: delete url
# %a: admin url/code
# %l: source (local) filename
# %m: module name
# %s: filesize (in bytes)
# %D: alias for "#DEL %d%n" or empty string (if %d is empty)
# %A: alias for "#ADM %a%n" or empty string (if %a is empty)
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
    S=${1//%[fudalmsADnt%]}
    TOKEN=$(parse_quiet . '\(%.\)' <<< "$S")
    if [ -n "$TOKEN" ]; then
        log_error "Bad format string: unknown sequence << $TOKEN >>"
        return $ERR_BAD_COMMAND_LINE
    fi
}

# $1: array[@] (module, lfile, dfile, dl, del, adm)
# $2: format string
pretty_print() {
    local -a A=("${!1}")
    local FMT=$2
    local -r CR=$'\n'

    test "${FMT#*%%}" != "$FMT" && FMT=$(replace_all '%%' "%raw" <<< "$FMT")

    if test "${FMT#*%D}" != "$FMT"; then
        if [ -z "${A[4]}" ]; then
            FMT=${FMT//%D/}
        else
            FMT=$(replace_all '%D' "#DEL %d%n" <<< "$FMT")
        fi
    fi

    if test "${FMT#*%A}" != "$FMT"; then
        if [ -z "${A[5]}" ]; then
            FMT=${FMT//%A/}
        else
            FMT=$(replace_all '%A' "#ADM %a%n" <<< "$FMT")
        fi
    fi

    test "${FMT#*%s}" != "$FMT" && \
        FMT=$(replace_all '%s' $(get_filesize "${A[1]}") <<< "$FMT")

    handle_tokens "$FMT" '%raw,%' '%t,	' "%n,$CR" \
        "%m,${A[0]}" "%l,${A[1]}" "%f,${A[2]}" "%u,${A[3]}" \
        "%d,${A[4]}" "%a,${A[5]}"
}

# Filename (arguments) printf format
# ---
# %f: destination (remote) filename
# %g: destination (remote) filename (without extension)
# %G: destination (remote) filename (without extension, greedy)
# %h: MD5 hash (32-digit hexadecimal number, lowercase letters)
# %l: source (local) filename
# %m: module name
# %s: filesize (in bytes)
# %x: extension (without dot character) of %f (not greedy)
# and also:
# %%: raw %
# ---
#
# Check user given format
# $1: format string
pretty_name_check() {
    # This must be non greedy!
    local S TOKEN
    S=${1//%[fgGhlmsx%]}
    TOKEN=$(parse_quiet . '\(%.\)' <<< "$S")
    if [ -n "$TOKEN" ]; then
        log_error "Bad format string: unknown sequence << $TOKEN >>"
        return $ERR_BAD_COMMAND_LINE
    fi

    S=$1
    if test "${S#*%}" = "$S"; then
        log_notice 'No pattern specified in --name. This is maybe not what you want.'
    fi
}

# $1: array[@] (module, lfile, dfile)
# $2: format string
pretty_name_print() {
    local -a A=("${!1}")
    local FMT=$2

    test "${FMT#*%%}" != "$FMT" && FMT=$(replace_all '%%' "%raw" <<< "$FMT")

    test "${FMT#*%s}" != "$FMT" && \
        FMT=$(replace_all '%s' $(get_filesize "${A[1]}") <<< "$FMT")

    test "${FMT#*%h}" != "$FMT" && \
        FMT=$(replace_all '%h' $(md5_file "${A[1]}") <<< "$FMT")

    handle_tokens "$FMT" '%raw,%' \
        "%m,${A[0]}" "%l,${A[1]}" "%f,${A[2]}" \
        "%x,${A[2]##*.}" "%g,${A[2]%.*}" "%G,${A[2]%%.*}"
}

#
# Main
#

# Check interpreter
if (( ${BASH_VERSINFO[0]} * 100 + ${BASH_VERSINFO[1]} <= 400 )); then
    echo "plowup: Your shell is too old. Bash 4.1+ is required." >&2
    echo "plowup: Your version is $BASH_VERSION" >&2
    exit 1
fi

if [[ $SHELLOPTS = *posix* ]]; then
    echo "plowup: Your shell is in POSIX mode, this will not work." >&2
    exit 1
fi

# Get library directory
LIBDIR=$(absolute_path "$0")
readonly LIBDIR
TMPDIR=${TMPDIR:-/tmp}

set -e # enable exit checking

source "$LIBDIR/core.sh"
mapfile -t MODULES < <(get_all_modules_list "$LIBDIR" 'upload') || exit
for MODULE in "${MODULES[@]}"; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Process command-line (plowup early options)
eval "$(process_core_options 'plowup' "$EARLY_OPTIONS" "$@")" || exit

test "$HELPFULL" && { usage 1; exit 0; }
test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

if test "$ALLMODULES"; then
    for MODULE in "${MODULES[@]}"; do echo "$MODULE"; done
    exit 0
fi

# Get configuration file options. Command-line is partially parsed.
test -z "$NO_PLOWSHARERC" && \
    process_configfile_options '[Pp]lowup' "$MAIN_OPTIONS" "$EXT_PLOWSHARERC"

declare -a COMMAND_LINE_MODULE_OPTS COMMAND_LINE_ARGS RETVALS
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}")

# Process command-line (plowup options).
# Note: Ignore returned UNUSED_ARGS[@], it will be empty.
eval "$(process_core_options 'plowup' "$MAIN_OPTIONS" "${UNUSED_OPTS[@]}")" || exit

# Verify verbose level
if [ -n "$QUIET" ]; then
    declare -r VERBOSE=0
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

if [ $# -lt 1 ]; then
    log_error 'plowup: no module specified!'
    log_error "plowup: try \`plowup --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

log_report_info "$LIBDIR"
log_report "plowup version $VERSION"

if [ -n "$EXT_PLOWSHARERC" ]; then
    if [ -n "$NO_PLOWSHARERC" ]; then
        log_notice 'plowup: --no-plowsharerc selected and prevails over --plowsharerc'
    else
        log_notice 'plowup: using alternate configuration file'
    fi
fi

if [ -n "$MAX_LIMIT_RATE" -a -n "$MIN_LIMIT_RATE" ]; then
  if (( MAX_LIMIT_RATE < MIN_LIMIT_RATE )); then
      log_error "--min-rate ($MIN_LIMIT_RATE) is greater than --max-rate ($MAX_LIMIT_RATE)"
      exit $ERR_BAD_COMMAND_LINE
  fi
fi

if [ -n "$TEMP_DIR" ]; then
    TMPDIR=${TEMP_DIR%/}
    log_notice "Temporary directory: $TMPDIR"
fi

if [ -n "$PRINTF_FORMAT" ]; then
    pretty_check "$PRINTF_FORMAT" || exit
fi

if [ -n "$NAME_FORMAT" ]; then
    pretty_name_check "$NAME_FORMAT" || exit
fi

if [ -n "$CAPTCHA_PROGRAM" ]; then
    log_debug 'plowup: --captchaprogram selected'
fi

if [ -n "$CAPTCHA_METHOD" ]; then
    captcha_method_translate "$CAPTCHA_METHOD" || exit
    log_notice "plowup: force captcha method ($CAPTCHA_METHOD)"
else
    [ -n "$CAPTCHA_9KWEU" ] && log_debug 'plowup: --9kweu selected'
    [ -n "$CAPTCHA_ANTIGATE" ] && log_debug 'plowup: --antigate selected'
    [ -n "$CAPTCHA_BHOOD" ] && log_debug 'plowup: --captchabhood selected'
    [ -n "$CAPTCHA_DEATHBY" ] && log_debug 'plowup: --deathbycaptcha selected'
fi

if [ -z "$NO_CURLRC" -a -f "$HOME/.curlrc" ]; then
    log_debug 'using local ~/.curlrc'
fi

MODULE_OPTIONS=$(get_all_modules_options MODULES[@] UPLOAD)

# Process command-line (all module options)
eval "$(process_all_modules_options 'plowup' "$MODULE_OPTIONS" \
    "${UNUSED_OPTS[@]}")" || exit

# Prepend here to keep command-line order
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}" "${COMMAND_LINE_ARGS[@]}")
COMMAND_LINE_MODULE_OPTS=("${UNUSED_OPTS[@]}")

if [ ${#COMMAND_LINE_ARGS[@]} -eq 0 ]; then
    log_error 'plowup: no module specified!'
    log_error "plowup: try \`plowup --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

# Check requested module
MODULE=$(module_exist MODULES[@] "${COMMAND_LINE_ARGS[0]}") || {
    log_error "plowup: unsupported module (${COMMAND_LINE_ARGS[0]})";
    exit $ERR_NOMODULE;
}

if [ ${#COMMAND_LINE_ARGS[@]} -lt 2 ]; then
    log_error 'plowup: you must specify a filename.'
    log_error "plowup: try \`plowup --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

# Get configuration file module options
test -z "$NO_PLOWSHARERC" && \
    process_configfile_module_options '[Pp]lowup' "$MODULE" UPLOAD "$EXT_PLOWSHARERC"

eval "$(process_module_options "$MODULE" UPLOAD \
    "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

if [ ${#UNUSED_OPTS[@]} -ne 0 ]; then
    log_notice "Unused option(s): ${UNUSED_OPTS[@]}"
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
            LOCALFILE=$(echo "${FILE%:*}" | strip | uri_encode)
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

    if test "$NAME_FORMAT"; then
        DATA=("$MODULE" "$LOCALFILE" "$DESTFILE")
        DESTFILE=$(pretty_name_print DATA[@] "$NAME_FORMAT")
    fi

    if match '[;,]' "$DESTFILE"; then
        log_notice "Skipping ($LOCALFILE): curl can't upload filenames that contain , or ;"
        continue
    fi

    log_notice "Starting upload ($MODULE): $LOCALFILE"
    log_notice "Destination file: $DESTFILE"

    timeout_init $TIMEOUT

    TRY=0

    # Module storage policy (part 1/2)
    if [ "$CACHE" = 'none' ]; then
        storage_reset
    fi

    ${MODULE}_vars_set

    while :; do
        :> "$UCOOKIE"
        URETVAL=0
        $FUNCTION "$UCOOKIE" "$LOCALFILE" \
            "$DESTFILE" >"$URESULT" || URETVAL=$?

        if [ $URETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
            read AWAIT <"$URESULT" || true
            if [ -z "$AWAIT" ]; then
                log_debug 'arbitrary wait'
            else
                log_debug 'arbitrary wait (from module)'
            fi
            wait ${AWAIT:-60} || { URETVAL=$?; break; }
        elif [[ $MAXRETRIES -eq 0 ]]; then
            break
        elif [ $URETVAL -ne $ERR_FATAL -a $URETVAL -ne $ERR_NETWORK -a \
                $URETVAL -ne $ERR_CAPTCHA ]; then
            break
        # Special case
        elif [ $URETVAL -eq $ERR_CAPTCHA -a "$CAPTCHA_METHOD" = 'none' ]; then
            log_debug 'captcha method set to none, abort'
            break
        elif (( MAXRETRIES < ++TRY )); then
            URETVAL=$ERR_MAX_TRIES_REACHED
            break
        fi

        log_notice "Starting upload ($MODULE): retry $TRY/$MAXRETRIES"
    done

    ${MODULE}_vars_unset

    if [ $URETVAL -eq 0 ]; then
        { read DL_URL; read DEL_URL; read ADMIN_URL_OR_CODE; } <"$URESULT" || true
        if [ -n "$DL_URL" ]; then

            # Sanity check
            if [[ $DL_URL =~ $'\r' ]]; then
                log_debug 'final link contains \r, remove it (consider fixing module)'
                DL_URL=${DL_URL//$'\r'}
            fi

            DATA=("$MODULE" "$LOCALFILE" "$DESTFILE" \
                  "$DL_URL" "$DEL_URL" "$ADMIN_URL_OR_CODE")
            pretty_print DATA[@] "${PRINTF_FORMAT:-%D%A%u%n}"
        else
            log_error 'Output URL expected'
            URETVAL=$ERR_FATAL
        fi
    elif [ $URETVAL -eq $ERR_LINK_NEED_PERMISSIONS ]; then
        log_error 'Insufficient permissions. Anonymous users cannot upload files?'
    elif [ $URETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
        log_error 'Upload feature seems disabled from upstream now'
    elif [ $URETVAL -eq $ERR_LOGIN_FAILED ]; then
        log_error 'Login process failed. Bad username/password or unexpected content'
    elif [ $URETVAL -eq $ERR_SIZE_LIMIT_EXCEEDED ]; then
        log_error 'Insufficient permissions (file size limit exceeded)'
    elif [ $URETVAL -eq $ERR_MAX_TRIES_REACHED ]; then
        log_error "Retry limit reached (max=$MAXRETRIES)"
    elif [ $URETVAL -eq $ERR_BAD_COMMAND_LINE ]; then
        log_error 'Wrong module option, check your command line'
    elif [ $URETVAL -eq $ERR_ASYNC_REQUEST ]; then
        log_error 'Asynchronous upload in progress'
    else
        log_error "Failed inside ${FUNCTION}() [$URETVAL]"
    fi
    RETVALS=(${RETVALS[@]} $URETVAL)
done

# Module storage policy (part 2/2)
if [ "$CACHE" != 'shared' ]; then
    storage_reset
fi

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
