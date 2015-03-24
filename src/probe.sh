#!/usr/bin/env bash
#
# Retrieve metadata from a download link (sharing site url)
# Copyright (c) 2013-2015 Plowshare team
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
HELPFUL,H,longhelp,,Exhaustive help info (with modules command-line options)
GETVERSION,,version,,Output plowprobe version information and exit
ALLMODULES,,modules,,Output available modules (one per line) and exit. Useful for wrappers.
EXT_PLOWSHARERC,,plowsharerc,f=FILE,Force using an alternate configuration file (overrides default search path)
NO_PLOWSHARERC,,no-plowsharerc,,Do not use any plowshare.conf configuration file"

declare -r MAIN_OPTIONS="
VERBOSE,v,verbose,c|0|1|2|3|4=LEVEL,Verbosity level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
GET_MODULE,,get-module,,Retrieve module name and exit. Faster than --printf=%m
INTERFACE,i,interface,s=IFACE,Force IFACE network interface
PRINTF_FORMAT,,printf,s=FORMAT,Print results in a given format (for each link). Default is \"%F%u%n\".
NO_COLOR,,no-color,,Disables log notice & log error output coloring
TRY_REDIRECTION,,follow,,If no module is found for link, follow HTTP redirects (curl -L). Default is disabled.
EXT_CURLRC,,curlrc,f=FILE,Force using an alternate curl configuration file (overrides ~/.curlrc)
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

# Guess if item is a generic URL (a simple link string) or a text file with links.
# $1: single URL or file (containing links)
process_item() {
    local -r ITEM=$1

    if match_remote_url "$ITEM"; then
        strip <<< "$ITEM"
    elif [ -f "$ITEM" ]; then
        local MATCH

        if check_exec 'file'; then
            [[ $(file -i "$ITEM") =~ \ charset=binary$ ]] && MATCH=1
        else
            [[ $ITEM =~ \.(zip|rar|tar|[7gx]z|bz2|mp[234g]|avi|mkv|jpg)$ ]] && MATCH=1
        fi

        if [ -z "$MATCH" ]; then
            # Discard empty lines and comments
            echo 'file'
            sed -ne '/^[[:space:]]*[^#[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p}' "$ITEM"
        else
            log_error "Skip: '$ITEM' seems to be a binary file, not a list of links"
        fi
    else
        log_error "Skip: cannot stat '$ITEM': No such file or directory"
    fi
}

# Print usage (on stdout)
# Note: Global array variable MODULES is accessed directly.
usage() {
    echo 'Usage: plowprobe [OPTIONS] [MODULE_OPTIONS] URL|FILE...'
    echo 'Retrieve metadata from file sharing download links.'
    echo
    echo 'Global options:'
    print_options "$EARLY_OPTIONS$MAIN_OPTIONS"
    test -z "$1" || print_module_options MODULES[@] PROBE
}

# Note: Global option $PRINTF_FORMAT is accessed directly.
probe() {
    local -r MODULE=$1
    local -r URL_RAW=$2
    local -r ITEM=$3

    local URL_ENCODED=$(uri_encode <<< "$URL_RAW")
    local FUNCTION=${MODULE}_probe
    local MAP I CHECK_LINK CAPS FILE_NAME FILE_SIZE FILE_HASH FILE_ID FILE_TS FILE_URL
    local -a DATA

    log_debug "Starting probing ($MODULE): $URL_ENCODED"

    local PCOOKIE=$(create_tempfile)
    local PRESULT=$(create_tempfile)

    # Capabilities:
    # - c: check link (module function return value)
    # - f: filename [1]
    # - h: filehash, unspecific digest [1]
    # - i: fileid [1]
    # - s: filesize in bytes. This can be approximative. [1]
    # - t: file timestamp, unspecific time format [1]
    # - v: file url (refactored by module). Can be different from input url.
    #
    # [1] Can be empty string if not available.
    CHECK_LINK=0

    if test "$PRINTF_FORMAT"; then
        CAPS=c
        for I in f h i s t v; do
            [[ ${PRINTF_FORMAT,,} = *%$I* ]] && CAPS+=$I
        done
    else
        CAPS=cfv
    fi

    $FUNCTION "$PCOOKIE" "$URL_ENCODED" "$CAPS" >"$PRESULT" || CHECK_LINK=$?
    mapfile -t DATA < "$PRESULT"

    rm -f "$PRESULT" "$PCOOKIE"

    if [[ ${#DATA[@]} -gt 0 ]]; then
        # Get mapping variable (we must keep order)
        MAP=${DATA[${#DATA[@]}-1]}
        unset DATA[${#DATA[@]}-1]
        MAP=${MAP//c}

        for I in "${!DATA[@]}"; do
            case ${MAP:$I:1} in
                f)
                    FILE_NAME=${DATA[$I]}
                    ;;
                h)
                    FILE_HASH=${DATA[$I]}
                    ;;
                i)
                    FILE_ID=${DATA[$I]}
                    ;;
                s)
                    FILE_SIZE=${DATA[$I]}
                    ;;
                t)
                    FILE_TS=${DATA[$I]}
                    ;;
                v)
                    FILE_URL=${DATA[$I]}
                    ;;
                *)
                    log_error "plowprobe: unknown capability \`${MAP:$I:1}', ignoring"
                    ;;
            esac
        done
    elif [ $CHECK_LINK -eq 0 ]; then
        log_notice "$FUNCTION returned no data, module probe function might be wrong"
    elif [ $CHECK_LINK -ne $ERR_LINK_DEAD ]; then
        log_debug "$FUNCTION returned no data"
    fi

    # Don't process dead links
    if [ $CHECK_LINK -eq 0 -o \
        $CHECK_LINK -eq $ERR_LINK_TEMP_UNAVAILABLE -o \
        $CHECK_LINK -eq $ERR_LINK_NEED_PERMISSIONS -o \
        $CHECK_LINK -eq $ERR_LINK_PASSWORD_REQUIRED ]; then

        if [ $CHECK_LINK -eq $ERR_LINK_PASSWORD_REQUIRED ]; then
            log_debug "Link active (with password): $URL_ENCODED"
        elif [ $CHECK_LINK -eq $ERR_LINK_NEED_PERMISSIONS ]; then
            log_debug "Link active (with permissions): $URL_ENCODED"
        else
            log_debug "Link active: $URL_ENCODED"
        fi

        DATA=("$MODULE" "$URL_RAW" "$CHECK_LINK" "$FILE_NAME" "$FILE_SIZE" \
              "$FILE_HASH" "$FILE_ID" "$FILE_TS" "${FILE_URL:-$URL_ENCODED}")
        pretty_print DATA[@] "${PRINTF_FORMAT:-%F%u%n}"

    elif [ $CHECK_LINK -eq $ERR_LINK_DEAD ]; then
        log_notice "Link is not alive: $URL_ENCODED"
    else
        log_error "Skip: \`$URL_ENCODED': failed inside ${FUNCTION}() [$CHECK_LINK]"
    fi

    return $CHECK_LINK
}

# Plowprobe printf format
# ---
# Interpreted sequences are:
# %c: probe return status (0, $ERR_LINK_DEAD, ...)
# %f: filename or empty string (if not available)
# %F: alias for "# %f%n" or empty string if %f is empty
# %h: filehash or empty string (if not available)
# %i: fileid, link identifier or empty string (if not available)
# %m: module name
# %s: filesize (in bytes) or empty string (if not available).
#     Note: it's often approximative.
# %u: download url
# %U: download url (JSON string)
# %v: alternate download url refactored by module. Alias for %u if not available.
# %V: alternate download url refactored by module (JSON string). Alias for %U if not available.
# %T: timestamp or empty string (if not available).
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
    S=${1//%[cfFhimsuUTntvV%]}
    TOKEN=$(parse_quiet . '\(%.\)' <<< "$S")
    if [ -n "$TOKEN" ]; then
        log_error "Bad format string: unknown sequence << $TOKEN >>"
        return $ERR_BAD_COMMAND_LINE
    fi
}

# $1: array[@] (module, dl_url, check_link, file_name, file_size, file_hash, file_id, timestamp, file_url)
# $2: format string
pretty_print() {
    local -a A=("${!1}")
    local FMT=$2
    local -r CR=$'\n'

    test "${FMT#*%%}" != "$FMT" && FMT=$(replace_all '%%' "%raw" <<< "$FMT")

    if test "${FMT#*%F}" != "$FMT"; then
        if [ -z "${A[3]}" ]; then
            FMT=${FMT//%F/}
            [ -z "$FMT" ] && return
        else
            FMT=$(replace_all '%F' "# %f%n" <<< "$FMT")
        fi
    fi

    handle_tokens "$FMT" '%raw,%' '%t,	' "%n,$CR" \
        "%m,${A[0]}" "%u,${A[1]}" "%c,${A[2]}" "%f,${A[3]}" \
        "%s,${A[4]}" "%h,${A[5]}" "%i,${A[6]}" "%T,${A[7]}" \
        "%U,$(json_escape "${A[1]}")" "%v,${A[8]}" "%V,$(json_escape "${A[8]}")"
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

declare -a MODULES=()
eval "$(get_all_modules_list probe)" || exit
for MODULE in "${!MODULES_PATH[@]}"; do
    source "${MODULES_PATH[$MODULE]}"
    MODULES+=("$MODULE")
done

# Process command-line (plowprobe early options)
eval "$(process_core_options 'plowprobe' "$EARLY_OPTIONS" "$@")" || exit

test "$HELPFUL" && { usage 1; exit 0; }
test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

if test "$ALLMODULES"; then
    for MODULE in "${MODULES[@]}"; do echo "$MODULE"; done
    exit 0
fi

# Get configuration file options. Command-line is partially parsed.
test -z "$NO_PLOWSHARERC" && \
    process_configfile_options '[Pp]lowprobe' "$MAIN_OPTIONS" "$EXT_PLOWSHARERC"

declare -a COMMAND_LINE_MODULE_OPTS COMMAND_LINE_ARGS RETVALS
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}")

# Process command-line (plowprobe options).
# Note: Ignore returned UNUSED_ARGS[@], it will be empty.
eval "$(process_core_options 'plowprobe' "$MAIN_OPTIONS" "${UNUSED_OPTS[@]}")" || exit

# Verify verbose level
if [ -n "$QUIET" ]; then
    declare -r VERBOSE=0
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

if [ -n "$NO_COLOR" ]; then
    unset COLOR
else
    declare -r COLOR=yes
fi

if [ "${#MODULES}" -le 0 ]; then
    log_error \
"-------------------------------------------------------------------------------
Your plowshare installation has currently no module.
($PLOWSHARE_CONFDIR/modules.d/ is empty)

In order to use plowprobe you must install some modules. Here is a quick start:
$ plowmod --install
-------------------------------------------------------------------------------"
fi

if [ $# -lt 1 ]; then
    log_error 'plowprobe: no URL specified!'
    log_error "plowprobe: try \`plowprobe --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

log_report_info "$LIBDIR"
log_report "plowprobe version $VERSION"

if [ -n "$EXT_PLOWSHARERC" ]; then
    if [ -n "$NO_PLOWSHARERC" ]; then
        log_notice 'plowprobe: --no-plowsharerc selected and prevails over --plowsharerc'
    else
        log_notice 'plowprobe: using alternate configuration file'
    fi
fi

if [ -n "$PRINTF_FORMAT" ]; then
    pretty_check "$PRINTF_FORMAT" || exit
fi

if [ -n "$EXT_CURLRC" ]; then
    if [ -n "$NO_CURLRC" ]; then
        log_notice 'plowprobe: --no-curlrc selected and prevails over --curlrc'
    else
        log_notice 'plowprobe: using alternate curl configuration file'
    fi
elif [ -z "$NO_CURLRC" -a -f "$HOME/.curlrc" ]; then
    log_debug 'using local ~/.curlrc'
fi

MODULE_OPTIONS=$(get_all_modules_options MODULES[@] PROBE)

# Process command-line (all module options)
eval "$(process_all_modules_options 'plowprobe' "$MODULE_OPTIONS" \
    "${UNUSED_OPTS[@]}")" || exit

# Prepend here to keep command-line order
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}" "${COMMAND_LINE_ARGS[@]}")
COMMAND_LINE_MODULE_OPTS=("${UNUSED_OPTS[@]}")

if [ ${#COMMAND_LINE_ARGS[@]} -eq 0 ]; then
    log_error 'plowprobe: no URL specified!'
    log_error "plowprobe: try \`plowprobe --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

set_exit_trap

for ITEM in "${COMMAND_LINE_ARGS[@]}"; do

    # Read links from stdin
    if [ "$ITEM" = '-' ]; then
        if [[ -t 0 || -S /dev/stdin ]]; then
            log_notice 'Wait links from stdin...'
        fi
        ITEM=$(create_tempfile '.stdin') || {
           log_error 'Cannot create temporary file';
           continue;
        }
        cat > "$ITEM"
    fi

    mapfile -t ELEMENTS < <(process_item "$ITEM")

    for URL in "${ELEMENTS[@]}"; do
        PRETVAL=0
        MODULE=$(get_module "$URL" MODULES[@]) || true

        if [ -z "$MODULE" ]; then
            if match_remote_url "$URL"; then
                if test "$TRY_REDIRECTION"; then
                    # Test for simple HTTP 30X redirection
                    # (disable User-Agent because some proxy can fake it)
                    log_debug 'No module found, try simple redirection'

                    URL_ENCODED=$(uri_encode <<< "$URL")
                    HEADERS=$(curl --user-agent '' -i "$URL_ENCODED") || true
                    URL_TEMP=$(grep_http_header_location_quiet <<< "$HEADERS")

                    if [ -n "$URL_TEMP" ]; then
                        MODULE=$(get_module "$URL_TEMP" MODULES[@]) || PRETVAL=$?
                        test "$MODULE" && URL=$URL_TEMP
                    else
                        match 'https\?://[[:digit:]]\{1,3\}\.[[:digit:]]\{1,3\}\.[[:digit:]]\{1,3\}\.[[:digit:]]\{1,3\}/' \
                            "$URL" && log_notice 'Raw IPv4 address not expected. Provide an URL with a DNS name.'
                        test "$HEADERS" && \
                            log_debug "remote server reply: $(first_line <<< "${HEADERS//$'\r'}")"
                        PRETVAL=$ERR_NOMODULE
                    fi
                else
                    PRETVAL=$ERR_NOMODULE
                fi
            else
                log_debug "Skip: '$URL' (in $ITEM) doesn't seem to be a link"
                PRETVAL=$ERR_NOMODULE
            fi
        fi

        if [ $PRETVAL -ne 0 ]; then
            match_remote_url "$URL" && \
                log_error "Skip: no module for URL ($(basename_url "$URL")/)"

            # Check if plowlist can handle $URL
            if [[ ! $MODULES2 ]]; then
                declare -a MODULES2=()
                eval "$(get_all_modules_list list probe)" || exit
                for MODULE in "${!MODULES_PATH[@]}"; do
                    source "${MODULES_PATH[$MODULE]}"
                    MODULES2+=("$MODULE")
                done
            fi
            MODULE=$(get_module "$URL" MODULES2[@]) || true
            if [ -n "$MODULE" ]; then
                log_notice "Note: This URL ($MODULE) is supported by plowlist"
            fi

            RETVALS+=($PRETVAL)
        elif test "$GET_MODULE"; then
            RETVALS+=(0)
            echo "$MODULE"
        else
            # Get configuration file module options
            test -z "$NO_PLOWSHARERC" && \
                process_configfile_module_options '[Pp]lowprobe' "$MODULE" PROBE "$EXT_PLOWSHARERC"

            eval "$(process_module_options "$MODULE" PROBE \
                "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

            ${MODULE}_vars_set
            probe "$MODULE" "$URL" "$ITEM" || PRETVAL=$?
            ${MODULE}_vars_unset

            RETVALS+=($PRETVAL)
        fi
    done
done

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
