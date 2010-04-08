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
# Global variables used:
#   - VERBOSE         Verbose log level (0=none, 1, 2, 3)
#   - INTERFACE       Network interface (used by curl)
#   - PS_TIMEOUT      Timeout (in seconds) for one URL download
#   - PS_RETRY_LIMIT  Number of tries for loops (mainly for captchas)
#   - LIBDIR          Absolute path to plowshare's libdir
set -o pipefail

# Logs are sent to standard error.
# Policy:
# - debug: modules messages, curl (intermediate) calls
# - notice: core messages (ocr, countdown, timeout, retries), lastest plowdown curl call
# - error: modules errors (when return 1)

verbose_level() { echo ${VERBOSE:-0}; }
 
log_debug() { test $(verbose_level) -ge 3 && debug "dbg: $@" || true; }

log_notice() { test $(verbose_level) -ge 2 && debug "$@" || true; }

log_error() { test $(verbose_level) -ge 1 && debug "$@" || true; }

# Wrapper for curl: debug and infinite loop control
curl() {
    local -a OPTIONS=(--insecure)
    local DRETVAL=0

    # no verbose unless debug level
    test $(verbose_level) -lt 3 && OPTIONS=(${OPTIONS[@]} "--silent")

    test -n "$INTERFACE" && OPTIONS=(${OPTIONS[@]} "--interface" "$INTERFACE")
    set -- $(type -P curl) "${OPTIONS[@]}" "$@"
    "$@" || DRETVAL=$?
    return $DRETVAL
#    while true; do
#        $(type -P curl) "${OPTIONS[@]}" "$@" || DRETVAL=$?
#        if [ $DRETVAL -eq 6 -o $DRETVAL -eq 7 ]; then
#            local WAIT=60
#            log_debug "curl failed with non-fatal retcode $DRETVAL"
#            log_debug "retry after a safety wait ($WAIT seconds)"
#            sleep $WAIT
#            continue
#        else
#            return $DRETVAL
#        fi
#    done
}

replace() {
    sed -e "s#$1#$2#g"
}

# Return uppercase string
uppercase() {
    tr '[a-z]' '[A-Z]'
}

# Get first line that matches a regular expression and extract string from it.
#
# $1: POSIX-regexp to filter (get only the first matching line).
# $2: POSIX-regexp to match (use parenthesis) on the matched line.
parse_all() {
    local STRING=$(sed -n "/$1/ s/^.*$2.*$/\1/p") &&
        test "$STRING" && echo "$STRING" ||
        { log_error "parse failed: /$1/ $2"; return 1; }
}

# Like parse_all, but get only first match
parse() {
    parse_all "$@" | head -n1
}

# Grep first "Location" (of http header)
#
# stdin: result of curl request (with -i/--include, -D/--dump-header or
#        or -I/--head flag)
grep_http_header_location() {
    sed -n 's/^[Ll]ocation:[[:space:]]\+\([^ ]*\)/\1/p' 2>/dev/null | tr -d "\r"
}

# Grep first "Content-Disposition" (of http header)
#
# stdin: same as grep_http_header_location() below
grep_http_header_content_disposition() {
    parse "[Cc]ontent-[Dd]isposition:" 'filename="\(.*\)"' 2>/dev/null
}

# Extract a specific form from a HTML content.
# We assume here that start marker <form> and end marker </form> are one separate lines.
# HTML comments are just ignored. But it's enough for our needs.
#
# $1: (X)HTML data
# $2: (optionnal) Nth <form> (default is 1)
# stdout: result
grep_form_by_order() {
    local DATA="$1"
    local N=${2:-"1"}

     while [ "$N" -gt "1" ]; do
         ((N--))
         DATA=$(echo "$DATA" | sed -ne '/<\/form>/,$p' | sed -e '1s/<\/form>/<_form>/1')
     done

     # FIXME: sed will be greedy, if other forms are remaining they will be returned
     echo "$DATA" | sed -ne '/<form /,/<\/form>/p'
}

# Extract a named form from a HTML content.
# If several forms have the same name, take first one.
#
# $1: (X)HTML data
# $2: "name" attribute of <form> marker
# stdout: result
grep_form_by_name() {
    local DATA="$1"

    if [ -n "$2" ]; then
        # FIXME: sed will be greedy, if other forms are remaining they will be returned
        echo "$DATA" | sed -ne "/<[Ff][Oo][Rr][Mm][[:space:]].*name=\"\?$2\"\?/,/<\/[Ff][Oo][Rr][Mm]>/p"
    fi
}

# Extract a id-specified form from a HTML content.
# If several forms have the same id, take first one.
#
# $1: (X)HTML data
# $2: "id" attribute of <form> marker
# stdout: result
grep_form_by_id() {
    local DATA="$1"

    if [ -n "$2" ]; then
        # FIXME: sed will be greedy, if other forms are remaining they will be returned
        echo "$DATA" | sed -ne "/<[Ff][Oo][Rr][Mm][[:space:]].*id=\"\?$2\"\?/,/<\/[Ff][Oo][Rr][Mm]>/p"
    fi
}

# Return value of html attribute
break_html_lines() {
    sed 's/\(<\/[^>]*>\)/\1\n/g'
}

# Return value of html attribute
parse_attr() {
    parse "$1" "$2"'="\([^"]*\)"'
}

# Return value of html attribute
parse_all_attr() {
    parse_all "$1" "$2"'="\([^"]*\)"'
}

# Retreive "action" attribute (URL) from a <form> marker
#
# stdin: (X)HTML data (idealy, call grep_form_by_xxx before)
# stdout: result
#
parse_form_action() {
    parse '<form' 'action="\([^"]*\)"'
}

# Retreive "value" attribute from a named <input> marker
#
# $1: name attribute of <input> marker
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_name() {
    parse "<input\([[:space:]]*[^ ]*\)*name=\"\?$1\"\?" 'value="\?\([^">]*\)' 2>/dev/null
}

# Retreive "value" attribute from a typed <input> marker
#
# $1: type attribute of <input> marker (for example: "submit")
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_type() {
    parse "<input\([[:space:]]*[^ ]*\)*type=\"\?$1\"\?" 'value="\?\([^">]*\)' 2>/dev/null
}

# Check if a string ($2) matches a regexp ($1)
# This is case sensitive.
#
# $? is zero on success
match() {
    grep -q "$1" <<< "$2"
}

# Check if a string ($2) matches a regexp ($1)
# This is not case sensitive.
#
# $? is zero on success
matchi() {
    grep -iq "$1" <<< "$2"
}

# Create a tempfile and return path
#
# $1: Suffix
create_tempfile() {
    SUFFIX=$1
    FILE="${TMPDIR:-/tmp}/$(basename $0).$$.$RANDOM$SUFFIX"
    : > "$FILE"
    echo "$FILE"
}

# Check existance of executable in path
#
# $1: Executable to check
check_exec() {
    type -P $1 > /dev/null
}

# Check if function is defined
check_function() {
    declare -F "$1" &>/dev/null
}

# Login and return cookies
#
# $1: String 'username:password' (password can contain semicolons)
# $2: Postdata string (ex: 'user=\$USER&password=\$PASSWORD')
# $3: URL to post
# $4: Additional curl arguments (optional)
post_login() {
    AUTH=$1
    POSTDATA=$2
    LOGINURL=$3
    CURL_ARGS=$4

    if [ -n "$AUTH" ]; then
        USER="${AUTH%%:*}"
        PASSWORD="${AUTH#*:}"

        if [ -z "$PASSWORD" -o "$AUTH" == "$PASSWORD" ]; then
            log_notice "No password specified, enter it now"
            stty -echo
            read -p "Enter password: " PASSWORD
            stty echo
        fi

        log_notice "Starting login process: $USER/$(sed 's/./*/g' <<< "$PASSWORD")"

        DATA=$(eval echo $(echo "$POSTDATA" | sed "s/&/\\\\&/g"))
        # Yes, no quote around $CURL_ARGS
        COOKIES=$(curl -o /dev/null -c - $CURL_ARGS --data "$DATA" "$LOGINURL")
        test "$COOKIES" || { log_error "login error"; return 1; }
        echo "$COOKIES"
    fi
}

# OCR of an image.
#
# $1: optional varfile
# stdin: image (binary)
# stdout: result OCRed text
ocr() {
    local OPT_CONFIGFILE="$LIBDIR/tesseract/plowshare_nobatch"
    local OPT_VARFILE="$LIBDIR/tesseract/$1"
    test -f "$OPT_VARFILE" || OPT_VARFILE=''

    # Tesseract somewhat "peculiar" arguments requirement makes impossible
    # to use pipes or process substitution. Create temporal files
    # instead (*sigh*).
    TIFF=$(create_tempfile ".tif")
    TEXT=$(create_tempfile ".txt")

    convert - tif:- > $TIFF
    LOG=$(tesseract $TIFF ${TEXT/%.txt} $OPT_CONFIGFILE $OPT_VARFILE 2>&1)
    if [ $? -ne 0 ]; then
        rm -f $TIFF $TEXT
        log_error "$LOG"
        return 1
    fi

    cat $TEXT
    rm -f $TIFF $TEXT
}

# Output image in ascii chars (aview uses libaa)
aview_ascii_image() {
    convert $1 -negate -depth 8 pnm:- |
      aview -width 60 -height 28 -kbddriver stdin -driver stdout <(cat) 2>/dev/null <<< "q"|
        sed  -e '1d;/\x0C/,/\x0C/d' |
          grep -v "^[[:space:]]*$"
}

caca_ascii_image() {
    img2txt -W 60 -H 14 $1
}

# Display image (in ascii) and forward it (like tee command)
#
# stdin: image (binary)
# stdout: same image
show_image_and_tee() {
    test $(verbose_level) -lt 3 && { cat; return; }
    local TEMPIMG=$(create_tempfile)
    cat > $TEMPIMG
    if which aview &>/dev/null; then
        aview_ascii_image $TEMPIMG >&2
    elif which img2txt &>/dev/null; then
        caca_ascii_image $TEMPIMG >&2
    else
        log_notice "Install aview or libcaca to display captcha image"
    fi
    cat $TEMPIMG
    rm -f $TEMPIMG
}


# Show help info for options
#
# $1: options
# $2: indent string
debug_options() {
    OPTIONS=$1
    INDENTING=$2
    while read OPTION; do
        test "$OPTION" || continue
        IFS="," read VAR SHORT LONG VALUE HELP <<< "$OPTION"
        STRING="$INDENTING"
        test "$SHORT" && {
            STRING="$STRING-${SHORT%:}"
            test "$VALUE" && STRING="$STRING $VALUE"
        }
        test "$LONG" -a "$SHORT" && STRING="$STRING, "
        test "$LONG" && {
            STRING="$STRING--${LONG%:}"
            test "$VALUE" && STRING="$STRING=$VALUE"
        }
        echo "$STRING: $HELP"
    done <<< "$OPTIONS"
}

# Look for a configuration module variable
# Example: MODULE_ZSHARE_DOWNLOAD_OPTIONS (result can be multiline)
get_modules_options() {
    MODULES=$1
    NAME=$2
    for MODULE in $MODULES; do
        get_options_for_module "$MODULE" "$NAME" | while read OPTION; do
            if test "$OPTION"; then echo "!$OPTION"; fi
        done
    done
}

continue_downloads() {
    MODULE=$1
    VAR="MODULE_$(echo $MODULE | uppercase)_DOWNLOAD_CONTINUE"
    test "${!VAR}" = "yes"
}

get_options_for_module() {
    MODULE=$1
    NAME=$2
    VAR="MODULE_$(echo $MODULE | uppercase)_${NAME}_OPTIONS"
    echo "${!VAR}"
}

# Show usage info for modules
debug_options_for_modules() {
    MODULES=$1
    NAME=$2
    for MODULE in $MODULES; do
        OPTIONS=$(get_options_for_module "$MODULE" "$NAME")
        if test "$OPTIONS"; then
            echo
            echo "Options for module <$MODULE>:"
            echo
            debug_options "$OPTIONS" "  "
        fi
    done
}

get_field() {
    echo "$2" | while IFS="," read LINE; do
        echo "$LINE" | cut -d"," -f$1
    done
}

quote() {
    for ARG in "$@"; do
        echo -n "$(declare -p ARG | sed "s/^declare -- ARG=//") "
    done | sed "s/ $//"
}

# Straighforward options and arguments processing using getopt style
#
# Example:
#
# $ set -- -a user:password -q arg1 arg2
# $ eval "$(process_options module "
#           AUTH,a:,auth:,USER:PASSWORD,Help for auth
#           QUIET,q,quiet,,Help for quiet" "$@")"
# $ echo "$AUTH / $QUIET / $1 / $2"
# user:password / 1 / arg1 / arg2
process_options() {
    local NAME=$1
    local OPTIONS=$2
    shift 2
    # Strip spaces in options
    local OPTIONS=$(grep -v "^[[:space:]]*$" <<< "$OPTIONS" | \
        sed "s/^[[:space:]]*//; s/[[:space:]]$//")
    while read VAR; do
        unset $VAR
    done < <(get_field 1 "$OPTIONS" | sed "s/^!//")
    local ARGUMENTS="$(getopt -o "$(get_field 2 "$OPTIONS")" \
        --long "$(get_field 3 "$OPTIONS")" -n "$NAME" -- "$@")"
    eval set -- "$ARGUMENTS"
    local -a UNUSED_OPTIONS=()
    while true; do
        test "$1" = "--" && { shift; break; }
        while read OPTION; do
            IFS="," read VAR SHORT LONG VALUE HELP <<< "$OPTION"
            UNUSED=0
            if test "${VAR:0:1}" = "!"; then
                UNUSED=1
                VAR=${VAR:1}
            fi
            if test "$1" = "-${SHORT%:}" -o "$1" = "--${LONG%:}"; then
                if test "${SHORT:${#SHORT}-1:1}" = ":" -o \
                        "${LONG:${#LONG}-1:1}" = ":"; then
                    if test "$UNUSED" = 0; then
                        echo "$VAR=$(quote "$2")"
                    else
                        if test "${1:0:2}" = "--"; then
                            UNUSED_OPTIONS=("${UNUSED_OPTIONS[@]}" "$1=$2")
                        else
                            UNUSED_OPTIONS=("${UNUSED_OPTIONS[@]}" "$1" "$2")
                        fi
                    fi
                    shift
                else
                    if test "$UNUSED" = 0; then
                        echo "$VAR=1"
                    else
                        UNUSED_OPTIONS=("${UNUSED_OPTIONS[@]}" "$1")
                    fi
                fi
                break
            fi
        done <<< "$OPTIONS"
        shift
    done
    echo "$(declare -p UNUSED_OPTIONS)"
    echo "set -- $(quote "$@")"
}

# Get module name from URL link
#
# $1: URL
get_module() {
    URL=$1
    MODULES=$2
    for MODULE in $MODULES; do
        VAR=MODULE_$(echo $MODULE | uppercase)_REGEXP_URL
        match "${!VAR}" "$URL" && { echo $MODULE; return; } || true
    done
}


# Related to --timeout plowdown command line option
timeout_init() {
    PS_TIMEOUT=$1
}

timeout_update() {
    local WAIT=$1
    test -z "$PS_TIMEOUT" && return
    log_notice "Time left to timeout: $PS_TIMEOUT secs"
    if test $(expr $PS_TIMEOUT - $WAIT) -lt 0; then
        log_error "timeout reached (asked $WAIT secs to wait, but remaining time is $PS_TIMEOUT)"
        return 1
    fi
    PS_TIMEOUT=$(expr $PS_TIMEOUT - $WAIT)
}


# Related to --max-retries plowdown command line option
retry_limit_init() {
    PS_RETRY_LIMIT=$1
}

retry_limit_not_reached() {
    test -z "$PS_RETRY_LIMIT" && return
    log_notice "Tries left: $PS_RETRY_LIMIT"
    (( PS_RETRY_LIMIT-- ))
    test "$PS_RETRY_LIMIT" -ge 0
}


# Countdown from VALUE (in UNIT_STR units) in STEP values
# Used by plowdown.
#
# $1: Sleep duration (arbitrary unit)
# $2: Debug message display interval (arbitrary unit)
# $3: User string naming unit (example: seconds, minutes). Only for debug message display.
# $4: How many seconds for 1 arbitrary unit
countdown() {
    local VALUE=$1
    local STEP=$2
    local UNIT_STR=$3
    local UNIT_SECS=$4

    test "$VALUE" -a "$STEP" -a "$UNIT_STR" -a "$UNIT_SECS" ||
        { log_error "countdown arguments error: $@"; return 1; }

    # Values in seconds
    local TOTAL_WAIT=$((VALUE * UNIT_SECS))
    local TOTAL_STEP=$((STEP * UNIT_SECS))

    timeout_update $TOTAL_WAIT || return 1

    log_notice -n "Waiting $VALUE $UNIT_STR... "

    REMAINING=$((VALUE))
    while [ "$REMAINING" -gt 0 ]; do
        MSG="$REMAINING left"
        log_notice -n "$MSG"
        BS=$(echo "$MSG" | sed -e 's/./\\b/g')

        if [ $REMAINING -le $STEP ]; then
            sleep $((REMAINING * UNIT_SECS))
            break
        fi

        sleep $TOTAL_STEP
        ((REMAINING -= STEP))

        log_notice -ne "\b $BS"
    done

    log_notice -ne "$BS"

    # Put some extra spaces to overwrite previous "x left" message
    log_notice "done!   "
}
