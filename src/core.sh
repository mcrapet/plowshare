#!/bin/bash
#
# Common set of functions used by modules
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

# Make pipes fail on the first failed command (requires Bash 3+)
set -o pipefail

# Global error codes
# 0 means success or link alive
declare -r ERR_FATAL=1                    # Unexpected result (upstream site updated, etc)
declare -r ERR_NOMODULE=2                 # No module found for processing request
declare -r ERR_NETWORK=3                  # Generic network error (socket failure, curl, firewall, etc)
declare -r ERR_LOGIN_FAILED=4             # Correct login/password argument is required
declare -r ERR_MAX_WAIT_REACHED=5         # Wait timeout (see -t/--timeout command line option)
declare -r ERR_MAX_TRIES_REACHED=6        # Max tries reached (see -r/--max-retries command line option)
declare -r ERR_CAPTCHA=7                  # Captcha solving failure
declare -r ERR_SYSTEM=8                   # System failure (missing executable, local filesystem, wrong behavior, etc)
declare -r ERR_LINK_TEMP_UNAVAILABLE=10   # plowdown: Link alive but temporarily unavailable
                                          # plowup: Feature (upload service) seems temporarily unavailable from upstream
                                          # plowlist: Links are temporarily unavailable. Upload still pending?
declare -r ERR_LINK_PASSWORD_REQUIRED=11  # Link alive but requires a password
declare -r ERR_LINK_NEED_PERMISSIONS=12   # plowdown: Link alive but requires some authentication (private or premium link)
                                          # plowup, plowdel: Operation not allowed for anonymous users
declare -r ERR_LINK_DEAD=13               # plowdel: File not found or previously deleted
                                          # plowlist: Remote folder does not exist or is empty
declare -r ERR_SIZE_LIMIT_EXCEEDED=14     # plowdown: Can't download link because file is too big (need permissions)
                                          # plowup: Can't upload too big file (need permissions)
declare -r ERR_BAD_COMMAND_LINE=15        # Unknown command line parameter or incompatible options
declare -r ERR_FATAL_MULTIPLE=100         # 100 + (n) with n = first error code (when multiple arguments)

# Global variables used (defined in other .sh)
#   - VERBOSE          Verbose log level (0=none, 1, 2, 3, 4)
#   - LIBDIR           Absolute path to plowshare's libdir
#   - INTERFACE        Network interface (used by curl)
#   - MAX_LIMIT_RATE   Network maximum speed (used by curl)
#   - MIN_LIMIT_RATE   Network minimum speed (used by curl)
#   - NO_CURLRC        Do not read of use curlrc config
#   - CAPTCHA_METHOD   (plowdown) User-specified captcha method
#   - CAPTCHA_TRADER   (plowdown) CaptchaTrader account
#   - CAPTCHA_ANTIGATE (plowdown) Antigate.com captcha key
#   - CAPTCHA_DEATHBY  (plowdown) DeathByCaptcha account
#   - MODULE           Module name (don't include .sh)
#
# Global variables defined here:
#   - PS_TIMEOUT       Timeout (in seconds) for one URL download
#
# Logs are sent to stderr stream.
# Policies:
# - error: modules errors (when return 1), lastest plowdown curl call
# - notice: core messages (wait, timeout, retries), lastest plowdown curl call
# - debug: modules messages, curl (intermediate) calls
# - report: debug plus curl content (html pages, cookies)

# log_report for a file
# $1: filename
logcat_report() {
    if test -s "$1"; then
        test $(verbose_level) -ge 4 && \
            stderr "$(sed -e 's/^/rep:/' "$1")"
    fi
    return 0
}

# This should not be called within modules
log_report() {
    test $(verbose_level) -ge 4 && stderr "rep: $@"
    return 0
}

log_debug() {
    test $(verbose_level) -ge 3 && stderr "dbg: $@"
    return 0
}

# This should not be called within modules
log_notice() {
    test $(verbose_level) -ge 2 && stderr "$@"
    return 0
}

log_error() {
    test $(verbose_level) -ge 1 && stderr "$@"
    return 0
}

## ----------------------------------------------------------------------------

##
## All helper functions below can be called by modules
## (see documentation...)
##

# Wrapper for curl: debug and infinite loop control
# $1..$n are curl arguments
# Important note: -D/--dump-header or -o/--output temporary files are deleted in case of error
curl() {
    local -a OPTIONS=(--insecure --compressed --speed-time 600 --connect-timeout 240 "$@")
    local -r CURL_PRG=$(type -P curl)
    local DRETVAL=0

    # Check if caller has specified a User-Agent, if so, don't put one
    if ! find_in_array OPTIONS[@] '-A' '--user-agent'; then
        OPTIONS[${#OPTIONS[@]}]='--user-agent'
        OPTIONS[${#OPTIONS[@]}]='Mozilla/5.0 (X11; Linux x86_64; rv:6.0) Gecko/20100101 Firefox/6.0'
    fi

    # Check if caller has allowed redirection, if so, limit it
    if find_in_array OPTIONS[@] '-L' '--location'; then
        OPTIONS[${#OPTIONS[@]}]='--max-redirs'
        OPTIONS[${#OPTIONS[@]}]=5
    fi

    # No verbose unless debug level; don't show progress meter for report level too
    test $(verbose_level) -ne 3 && OPTIONS[${#OPTIONS[@]}]='--silent'

    test -n "$NO_CURLRC" && OPTIONS=('-q' "${OPTIONS[@]}")

    if test -n "$INTERFACE"; then
        OPTIONS[${#OPTIONS[@]}]='--interface'
        OPTIONS[${#OPTIONS[@]}]=$INTERFACE
    fi
    if test -n "$MAX_LIMIT_RATE"; then
        OPTIONS[${#OPTIONS[@]}]='--limit-rate'
        OPTIONS[${#OPTIONS[@]}]=$MAX_LIMIT_RATE
    fi
    if test -n "$MIN_LIMIT_RATE"; then
        OPTIONS[${#OPTIONS[@]}]='--speed-time'
        OPTIONS[${#OPTIONS[@]}]=30
        OPTIONS[${#OPTIONS[@]}]='--speed-limit'
        OPTIONS[${#OPTIONS[@]}]=$MIN_LIMIT_RATE
    fi

    if test $(verbose_level) -lt 4; then
        "$CURL_PRG" "${OPTIONS[@]}" || DRETVAL=$?
    else
        local TEMPCURL=$(create_tempfile)
        log_report "${OPTIONS[@]}"
        "$CURL_PRG" --show-error "${OPTIONS[@]}" 2>&1 | tee "$TEMPCURL" || DRETVAL=$?
        FILESIZE=$(get_filesize "$TEMPCURL")
        log_report "Received $FILESIZE bytes"
        log_report "=== CURL BEGIN ==="
        logcat_report "$TEMPCURL"
        log_report "=== CURL END ==="
        rm -f "$TEMPCURL"
    fi

    if [ "$DRETVAL" != 0 ]; then
        local INDEX F

        if INDEX=$(index_in_array OPTIONS[@] '-D' '--dump-header'); then
            F=${OPTIONS[$INDEX]}
            if [ -f "$F" ]; then
                log_debug "deleting temporary HTTP header file: $F"
                rm -f "$F"
            fi
        fi

        if INDEX=$(index_in_array OPTIONS[@] '-o' '--output'); then
            F=${OPTIONS[$INDEX]}
            # Test to reject "-o /dev/null" and final plowdown call
            if [ -f "$F" ] && ! find_in_array OPTIONS[@] '--globoff'; then
                log_debug "deleting temporary output file: $F"
                rm -f "$F"
            fi
        fi

        case "$DRETVAL" in
            # Failed to initialize.
            2)
                log_error "out of memory?"
                return $ERR_SYSTEM
                ;;
            # Failed to connect to host.
            7)
                log_error "can't connect: DNS or firewall error"
                return $ERR_NETWORK
                ;;
            # Partial file
            18)
                return $ERR_LINK_TEMP_UNAVAILABLE
                ;;
            # HTTP retrieve error / Operation timeout
            22 | 28)
                log_error "curl retrieve error"
                return $ERR_NETWORK
                ;;
            # Write error
            23)
                log_error "write failed, disk full?"
                return $ERR_SYSTEM
                ;;
            *)
                log_error "curl failed ($DRETVAL)"
                return $ERR_NETWORK
                ;;
        esac
    fi
    return 0
}

# Force debug verbose level (unless -v0/-q specified)
curl_with_log() {
    local TEMP_VERBOSE=$(verbose_level)

    if [ "$TEMP_VERBOSE" -eq 0 ]; then
        TEMP_VERBOSE=0
    elif [ "$TEMP_VERBOSE" -lt 3 ]; then
        TEMP_VERBOSE=3
    fi

    VERBOSE=$TEMP_VERBOSE curl "$@"
}

# Substring replacement (replace all matches)
#
# stdin: input string
# $1: substring to find (this is not a regexp)
# $2: replacement string (this is not a regexp)
replace() {
    # Using $(< /dev/stdin) gives same results
    local S=$(cat)
    # We must escape '\' character
    local FROM=${1//\\/\\\\}
    echo "${S//$FROM/$2}"
}

# Delete leading and trailing whitespace.
# stdin: input string (can be multiline)
# stdout: result string
strip() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Return uppercase string : tr '[:lower:]' '[:upper:]'
# Note: Busybox "tr" command may not have classes support (CONFIG_FEATURE_TR_CLASSES)
# $*: input string(s)
uppercase() {
    tr '[a-z]' '[A-Z]' <<< "$*"
}

# Return lowercase string : tr '[:upper:]' '[:lower:]'
# $*: input string(s)
lowercase() {
    tr '[A-Z]' '[a-z]' <<< "$*"
}

# Grep first line of a text
# stdin: input string (multiline)
first_line() {
    # equivalent to `sed -ne 1p` or `sed -e q` or `sed -e 1q`
    head -n1
}

# Grep last line of a text
# stdin: input string (multiline)
last_line() {
    # equivalent to `sed -ne '$p'` or `sed -e '$!d'`
    tail -n1
}

# Grep nth line of a text
# stdin: input string (multiline)
# $1: line number (start at index 1)
nth_line() {
   # equivalent to `sed -e "${1}q;d"` or `sed -e "${1}!d"`
   sed -ne "${1}p"
}

# Delete fist line of a text
# stdin: input string (multiline)
delete_first_line() {
    # equivalent to `tail -n +2`
    sed -ne '2,$p'
}

# Delete last line of a text
# stdin: input string (multiline)
delete_last_line() {
    sed -e '$d'
}

# Check if a string ($2) matches a regexp ($1)
# This is case sensitive.
#
# $? is zero on success
match() {
    grep -q -- "$1" <<< "$2"
}

# Check if a string ($2) matches a regexp ($1)
# This is not case sensitive.
#
# $? is zero on success
matchi() {
    grep -iq -- "$1" <<< "$2"
}

# Check if URL is suitable for remote upload
#
# $1: string (URL or anything)
match_remote_url() {
    matchi '^[[:space:]]*https\?://' "$1"
}

# Get lines that match filter+match regular expressions and extract string from it.
#
# $1: regexp to filter (take lines matching $1 pattern)
# $2: regexp to match (must contain parentheses). Example: "url:'\(http.*\)'"
# $3: (optional) how many lines to skip (default is 0, filter and match regexp on same line).
#     Example ($3=1): get lines that first filter regexp, then apply match regexp on the line after.
# stdin: text data
# stdout: result
parse_all() {
    local N=${3:-0}
    local STRING REGEXP SKIP

    # Change sed separator to accept '/' characters
    local -r D=$'\001'

    if [ '^' = "${2:0:1}" ]; then
        if [ '$' = "${2:(-1):1}" ]; then
            REGEXP=$2
        else
            REGEXP="$2.*$"
        fi
    elif [ '$' = "${2:(-1):1}" ]; then
        REGEXP="^.*$2"
    else
        REGEXP="^.*$2.*$"
    fi

    if (( N > 0 )); then
        [ "$N" -gt 10 ] && \
            log_notice "$FUNCNAME: are you sure you want to skip $N lines?"
        while (( N-- )); do
            SKIP="${SKIP}n;"
        done
        # STRING=$(sed -n "/$1/{n;s/$REGEXP/\1/p}")
        STRING=$(sed -n "\\${D}$1${D}{${SKIP}s${D}$REGEXP${D}\1${D}p}")
    elif [ "$2" = '.' ]; then
        # STRING=$(sed -n "s/$REGEXP/\1/p")
        STRING=$(sed -n "s${D}$REGEXP${D}\1${D}p")
    else
        # STRING=$(sed -n "/$1/s/$REGEXP/\1/p")
        STRING=$(sed -n "\\${D}$1${D}s${D}$REGEXP${D}\1${D}p")
    fi

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"/$1/s/$REGEXP/\""
        log_notice_stack
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Like parse_all, but hide possible error
parse_all_quiet() {
    parse_all "$@" 2>/dev/null
    return 0
}

# Like parse_all, but get only first match
parse() {
    parse_all "$@" | head -n1
}

# Like parse, but hide possible error
parse_quiet() {
    parse "$@" 2>/dev/null
    return 0
}

# Like parse_all, but get only last match
parse_last() {
    parse_all "$@" | tail -n1
}

# Simple and limited JSON parsing
#
# Notes:
# - Single line parsing oriented (user should strip newlines first): no tree model
# - Array and Object types: no support
# - String type: no support for escaped unicode characters (\uXXXX)
# - No non standard C/C++ comments handling (like in JSONP)
# - If several entries exist on same line: last occurrence is taken, but:
#   consider precedence (order of priority): number, boolean/empty, string.
# - If several entries exist on different lines: all are returned (it's a parse_all_json)
#
# $1: variable name (string)
# $2: (optional) preprocess option. Accepted values are:
#     - "join": make a single line of input stream.
#     - "split": split input buffer on comma character (,).
# stdin: JSON data
# stdout: result
parse_json() {
    local STRING PRE
    local -r END='\([,}[:space:]].*\)\?$'

    if [ "$2" = 'join' ]; then
        PRE="tr -d '\n\r'"
    elif [ "$2" = 'split' ]; then
        PRE=sed\ -e\ 's/,[[:space:]]*"/\n"/g'
    else
        PRE='cat'
    fi

    STRING=$($PRE | sed \
        -ne "s/^.*\"$1\"[[:space:]]*:[[:space:]]*\(-\?\(0\|[1-9][[:digit:]]*\)\(\.[[:digit:]]\+\)\?\([eE][-+]\?[[:digit:]]\+\)\?\)$END/\1/p" \
        -ne "s/^.*\"$1\"[[:space:]]*:[[:space:]]*\(true\|false\|null\)$END/\1/p" \
        -ne "s/\\\\\"/\\\\q/g;s/^.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"$END/\1/p")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (json): \"$1\""
        log_notice_stack
        return $ERR_FATAL
    fi

    # Translate two-character sequence escape representations
    STRING=${STRING//\\\//\/}
    STRING=${STRING//\\\\/\\}
    STRING=${STRING//\\q/\"}
    STRING=${STRING//\\b/$'\b'}
    STRING=${STRING//\\f/$'\f'}
    STRING=${STRING//\\n/$'\n'}
    STRING=${STRING//\\r/$'\r'}
    STRING=${STRING//\\t/	}

    echo "$STRING"
}

# Like parse_json, but hide possible error
parse_json_quiet() {
    parse_json "$@" 2>/dev/null
    return 0
}

# Check if JSON variable is true
#
# $1: JSON variable name
# $2: JSON data
# $? is zero on success
match_json_true() {
    grep -q "\"$1\"[[:space:]]*:[[:space:]]*true" <<< "$2"
}

# Grep "Xxx" HTTP header. Can be:
# - Location
# - Content-Location
# - Content-Type
#
# Notes:
# - This is using parse_all, so result can be multiline
#   (rare usage is: curl -I -L ...).
# - Use [:cntrl:] intead of \r because Busybox sed <1.19
#   does not support it.
#
# stdin: result of curl request (with -i/--include, -D/--dump-header
#        or -I/--head flag)
# stdout: result
grep_http_header_location() {
    parse_all '^[Ll]ocation:' 'n:[[:space:]]\+\(.*\)[[:cntrl:]]$'
}
grep_http_header_location_quiet() {
    parse_all '^[Ll]ocation:' 'n:[[:space:]]\+\(.*\)[[:cntrl:]]$' 2>/dev/null
    return 0
}
grep_http_header_content_location() {
    parse_all '^[Cc]ontent-[Ll]ocation:' 'n:[[:space:]]\+\(.*\)[[:cntrl:]]$'
}
grep_http_header_content_type() {
    parse_all '^[Cc]ontent-[Tt]ype:' 'e:[[:space:]]\+\(.*\)[[:cntrl:]]$'
}

# Grep "Content-Disposition" HTTP header
#
# stdin: HTTP response headers (see below)
# stdout: attachement filename
grep_http_header_content_disposition() {
    parse_all '^[Cc]ontent-[Dd]isposition:' "filename=[\"']\?\([^\"'[:cntrl:]]*\)"
}

# Extract a specific form from a HTML content.
# Notes:
# - start marker <form> and end marker </form> must be on separate lines
# - HTML comments are just ignored
#
# $1: (X)HTML data
# $2: (optional) Nth <form> Index start at 1: first form of page.
#     Negative index possible: -1 means last form of page and so on.
#     Zero or empty value means 1.
# stdout: result
grep_form_by_order() {
    local DATA=$1
    local N=${2:-'1'}
    local DOT

    # Check numbers de <form> tags
    DOT=$(echo "$DATA" | sed -ne '/<[Ff][Oo][Rr][Mm][[:space:]]/s/.*/./p' | tr -d '\n')
    if (( $N < 0 )); then
        N=$(( ${#DOT} + 1 + N ))
        if (( $N <= 0 )); then
            log_error "$FUNCNAME failed: negative index is too big (detected ${#DOT} forms)"
            return $ERR_FATAL
        fi
    fi

    while [ "$N" -gt "1" ]; do
        (( --N ))
        DATA=$(echo "$DATA" | sed -ne '/<\/[Ff][Oo][Rr][Mm]>/,$p' | \
            sed -e '1s/<\/[Ff][Oo][Rr][Mm]>/<_FORM_>/1')

        test -z "$DATA" && break
    done

    # Get first form only
    local STRING=$(sed -ne \
        '/<[Ff][Oo][Rr][Mm][[:space:]]/,/<\/[Ff][Oo][Rr][Mm]>/{p;/<\/[Ff][Oo][Rr][Mm]/q}' <<<"$DATA")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"n=$N\""
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Extract a named form from a HTML content.
# Notes:
# - if several forms (with same name) are available: return all of them
# - start marker <form> and end marker </form> must be on separate lines
# - HTML comments are just ignored
#
# $1: (X)HTML data
# $2: (optional) "name" attribute of <form> marker.
#     If not specified: take forms having any "name" attribute (empty or not)
# stdout: result
grep_form_by_name() {
    local -r A=${2:-'.*'}
    local STRING=$(sed -ne \
        "/<[Ff][Oo][Rr][Mm][[:space:]].*name[[:space:]]*=[[:space:]]*[\"']\?$A[\"']\?/,/<\/[Ff][Oo][Rr][Mm]>/p" <<< "$1")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"name=$A\""
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Extract a id-specified form from a HTML content.
# Notes:
# - if several forms (with same name) are available: return all of them
# - start marker <form> and end marker </form> must be on separate lines
# - HTML comments are just ignored
#
# $1: (X)HTML data
# $2: (optional) "id" attribute of <form> marker.
#     If not specified: take forms having any "id" attribute (empty or not)
# stdout: result
grep_form_by_id() {
    local A=${2:-'.*'}
    local STRING=$(sed -ne \
        "/<[Ff][Oo][Rr][Mm][[:space:]].*id[[:space:]]*=[[:space:]]*[\"']\?$A[\"']\?/,/<\/[Ff][Oo][Rr][Mm]>/p" <<< "$1")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"id=$A\""
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Split into several lines html markers.
# Insert a new line after ending marker.
#
# stdin: (X)HTML data
# stdout: result
break_html_lines() {
    sed -e 's/<\/[^>]*>/&\n/g'
}

# Split into several lines html markers.
# Insert a new line after each (beginning or ending) marker.
#
# stdin: (X)HTML data
# stdout: result
break_html_lines_alt() {
    sed -e 's/<[^>]*>/&\n/g'
}

# Parse single named HTML marker content
# <tag>..</tag>
# <tag attr="x">..</tag>
# Notes:
# - beginning and ending tag are on the same line
# - this is non greedy, first occurrence is taken
# - marker is case sensitive, it should not
# - "parse_xxx tag" is a shortcut for "parse_xxx tag tag"
#
# $1: (optional) regexp to filter (take lines matching $1 pattern)
# $2: tag name. Example: "span"
# stdin: (X)HTML data
# stdout: result
parse_all_tag() {
    local -r T=${2:-"$1"}
    local -r D=$'\001'
    local STRING=$(sed -ne "\\${D}$1${D}s${D}</$T>.*${D}${D}p" | \
                   sed -e "s/^.*<$T\(>\|[[:space:]][^>]*>\)//")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"/$1/ <$T>\""
        log_notice_stack
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Like parse_all_tag, but hide possible error
parse_all_tag_quiet() {
    parse_all_tag "$@" 2>/dev/null
    return 0
}

# Like parse_all_tag, but get only first match
parse_tag() {
    parse_all_tag "$@" | head -n1
}

# Like parse_tag, but hide possible error
parse_tag_quiet() {
    parse_tag "$@" 2>/dev/null
    return 0
}

# Parse HTML attribute content
# http://www.w3.org/TR/html-markup/syntax.html#syntax-attributes
# Notes:
# - empty attribute syntax is not supported (ex: <input disabled>)
# - this is greedy, last occurrence is taken
# - attribute is case sensitive, it should not
# - "parse_xxx attr" is a shortcut for "parse_xxx attr attr"
#
# $1: (optional) regexp to filter (take lines matching $1 pattern)
# $2: attribute name. Example: "href"
# stdin: (X)HTML data
# stdout: result
parse_all_attr() {
    local -r A=${2:-"$1"}
    local -r D=$'\001'
    local STRING=$(sed \
        -ne "\\${D}$1${D}s${D}.*[[:space:]]$A[[:space:]]*=[[:space:]]*[\"']\([^\"'>]*\).*${D}\1${D}p" \
        -ne "\\${D}$1${D}s${D}.*[[:space:]]$A[[:space:]]*=[[:space:]]*\([^[:space:]\"'<=>/]\+\).*${D}\1${D}p")
    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"/$1/ $A=\""
        log_notice_stack
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Like parse_all_attr, but hide possible error
parse_all_attr_quiet() {
    parse_all_attr "$@" 2>/dev/null
    return 0
}

# Return value of html attribute
parse_attr() {
    parse_all_attr "$@" | head -n1
}

# Like parse_attr, but hide possible error
parse_attr_quiet() {
    parse_attr "$@" 2>/dev/null
    return 0
}

# Retrieve "action" attribute (URL) from a <form> marker
#
# stdin: (X)HTML data (idealy, call grep_form_by_xxx before)
# stdout: result
parse_form_action() {
    parse_attr '<[Ff][Oo][Rr][Mm]' 'action'
}

# Retrieve "value" attribute from an <input> marker with "name" attribute
# Note: "value" attribute must be placed after "name" attribute.
#
# $1: name attribute of <input> marker
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_name() {
    parse "<[Ii][Nn][Pp][Uu][Tt]\([[:space:]]*[^ ]*\)*name=[\"']\?$1[\"']\?" "value=[\"']\?\([^'\">]*\)"
}

# Like parse_form_input_by_name, but hide possible error
parse_form_input_by_name_quiet() {
    parse_form_input_by_name "$@" 2>/dev/null
    return 0
}

# Retrieve "value" attribute from an <input> marker with "type" attribute
# Note: "value" attribute must be placed after "type" attribute.
#
# $1: type attribute of <input> marker (for example: "submit")
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_type() {
    parse "<[Ii][Nn][Pp][Uu][Tt]\([[:space:]]*[^ ]*\)*type=[\"']\?$1[\"']\?" "value=[\"']\?\([^'\">]*\)"
}

# Like parse_form_input_by_type, but hide possible error
parse_form_input_by_type_quiet() {
    parse_form_input_by_type "$@" 2>/dev/null
    return 0
}

# Retrieve "value" attribute from an <input> marker with "id" attribute
# Note: "value" attribute must be placed after "id" attribute.
#
# $1: id attribute of <input> marker
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_id() {
    parse "<[Ii][Nn][Pp][Uu][Tt]\([[:space:]]*[^ ]*\)*id=[\"']\?$1[\"']\?" "value=[\"']\?\([^'\">]*\)"
}

# Like parse_form_input_by_id, but hide possible error
parse_form_input_by_id_quiet() {
    parse_form_input_by_id "$@" 2>/dev/null
    return 0
}

# Get specific entry (value) from cookie
#
# $1: entry name (example: "lang")
# stdin: cookie data (netscape/mozilla cookie file format)
# stdout: result (can be null string no suck entry exists)
parse_cookie() {
    parse_all "\t$1\t[^\t]*\$" "\t$1\t\(.*\)"
}
parse_cookie_quiet() {
    parse_all "\t$1\t[^\t]*\$" "\t$1\t\(.*\)" 2>/dev/null
    return 0
}

# Return base of URL
# Examples:
# - http://www.host.com => http://www.host.com
# - http://www.host.com/a/b/c/d => http://www.host.com
# - http://www.host.com?sid=123 => http://www.host.com
# Note: Don't use `expr` (GNU coreutils) for portability purposes.
#
# $1: URL
basename_url() {
    sed -e 's=\(https\?://[^/?#]*\).*=\1=' <<<"$1"
}

# Return basename of file path
# Example: /usr/bin/foo.bar => foo.bar
#
# $1: filename
basename_file() {
    # `basename -- "$1"` may be screwed on some BusyBox versions
    echo "${1##*/}"
}

# HTML entities will be translated
#
# stdin: data
# stdout: data (converted)
html_to_utf8() {
    if check_exec 'recode'; then
        log_report "$FUNCNAME: use recode"
        recode html..utf8
    elif check_exec 'perl'; then
        log_report "$FUNCNAME: use perl"
        perl -n -mHTML::Entities \
            -e 'BEGIN { eval { binmode(STDOUT,q[:utf8]); }; } \
                print HTML::Entities::decode_entities($_);' 2>/dev/null || { \
            log_debug "$FUNCNAME failed (perl): HTML::Entities missing ?";
            cat;
        }
    else
        log_notice "recode binary not found, pass-through"
        cat
    fi
}

# Encode a text to include into an url.
# - Reserved Characters (18): !*'();:@&=+$,/?#[]
# - Check for percent (%) and space character
#
# - Unreserved Characters: ALPHA / DIGIT / "-" / "." / "_" / "~"
# - Unsafe characters (RFC2396) should not be percent-encoded anymore: <>{}|\^`
#
# stdin: data (example: relative URL)
# stdout: data (should complain RFC3986)
uri_encode_strict() {
    sed -e 's/\%/%25/g' -e 's/ /%20/g' \
        -e 's/!/%21/g' -e 's/*/%2A/g' -e 's/'\''/%27/g' \
        -e 's/(/%28/g' -e 's/)/%29/g' -e 's/;/%3B/g'    \
        -e 's/:/%3A/g' -e 's/@/%40/g' -e 's/&/%26/g'    \
        -e 's/=/%3D/g' -e 's/+/%2B/g' -e 's/\$/%24/g'   \
        -e 's/,/%2C/g' -e 's|/|%2F|g' -e 's/?/%3F/g'    \
        -e 's/#/%23/g' -e 's/\[/%5B/g' -e 's/\]/%5D/g'
}

# Encode a complete url.
# - check for space character and squares brackets
# - do not check for "reserved characters" (use "uri_encode_strict" for that)
#
# Bad encoded URL request can lead to HTTP error 400.
# curl doesn't do any checks, whereas wget convert provided url.
#
# stdin: data (example: absolute URL)
# stdout: data (nearly complain RFC3986)
uri_encode() {
    sed -e 's/ /%20/g' -e 's/\[/%5B/g' -e 's/\]/%5D/g'
}

# Decode a complete url.
# - check for space character and round/squares brackets
# - reserved characters: only coma is checked
#
# stdin: data (example: absolute URL)
# stdout: data (nearly complain RFC3986)
uri_decode() {
    sed -e 's/%20/ /g' -e 's/%26/\&/g' -e 's/%2C/,/g' -e 's/%28/(/g' \
        -e 's/%29/)/g' -e 's/%2B/+/g' -e 's/%3D/=/g' -e 's/%5B/\[/g' -e 's/%5D/\]/g'
}

# Retrieves size of file
#
# $1: filename
# stdout: file length (in bytes)
get_filesize() {
    local FILE_SIZE=$(stat -c %s "$1" 2>/dev/null)
    if [ -z "$FILE_SIZE" ]; then
        FILE_SIZE=$(ls -l "$1" 2>/dev/null | cut -d' ' -f5)
        if [ -z "$FILE_SIZE" ]; then
            log_error "can't get file size"
            echo '-1'
            return $ERR_SYSTEM
        fi
    fi
    echo "$FILE_SIZE"
}

# Create a tempfile and return path
# Note for later: use mktemp (GNU coreutils)
#
# $1: Suffix
create_tempfile() {
    local SUFFIX=$1
    local FILE="${TMPDIR:-/tmp}/$(basename_file "$0").$$.$RANDOM$SUFFIX"
    :> "$FILE" || return $ERR_SYSTEM
    echo "$FILE"
}

# User password entry
#
# stdout: entered password (can be null string)
# $? is non zero if no password
prompt_for_password() {
    local PASSWORD

    log_notice "No password specified, enter it now"

    # Unset IFS to consider trailing and leading spaces
    IFS= read -s -r -p 'Enter password: ' PASSWORD

    # Add missing trailing newline (see read -p)
    stderr

    test -z "$PASSWORD" && return $ERR_LINK_PASSWORD_REQUIRED
    echo "$PASSWORD"
}

# Login and return cookie.
# A non empty cookie file does not means that login is successful.
#
# $1: String 'username:password' (password can contain semicolons)
# $2: Cookie filename (see create_tempfile() modules)
# $3: Postdata string (ex: 'user=$USER&password=$PASSWORD')
# $4: URL to post
# $5, $6, ...: Additional curl arguments (optional)
# stdout: html result (can be null string)
# $? is zero on success
post_login() {
    local AUTH=$1
    local COOKIE=$2
    local POSTDATA=$3
    local LOGIN_URL=$4
    shift 4
    local -a CURL_ARGS=("$@")
    local USER PASSWORD DATA RESULT

    if [ -z "$AUTH" ]; then
        log_error "$FUNCNAME: authentication string is empty"
        return $ERR_LOGIN_FAILED
    fi

    if [ -z "$COOKIE" ]; then
        log_error "$FUNCNAME: cookie file expected"
        return $ERR_LOGIN_FAILED
    fi

    # Seem faster than
    # IFS=":" read USER PASSWORD <<< "$AUTH"
    USER=$(echo "${AUTH%%:*}" | uri_encode_strict)
    PASSWORD=$(echo "${AUTH#*:}" | uri_encode_strict)

    if [ -z "$PASSWORD" -o "$AUTH" = "${AUTH#*:}" ]; then
        PASSWORD=$(prompt_for_password) || true
    fi

    log_notice "Starting login process: $USER/${PASSWORD//?/*}"

    DATA=$(eval echo "${POSTDATA//&/\\&}")
    RESULT=$(curl --cookie-jar "$COOKIE" --data "$DATA" "${CURL_ARGS[@]}" "$LOGIN_URL") || return

    # "$RESULT" can be empty, this is not necessarily an error
    if [ ! -s "$COOKIE" ]; then
        log_debug "$FUNCNAME failed (empty cookie)"
        return $ERR_LOGIN_FAILED
    fi

    log_report "=== COOKIE BEGIN ==="
    logcat_report "$COOKIE"
    log_report "=== COOKIE END ==="

    if ! find_in_array CURL_ARGS[@] '-o' '--output'; then
        echo "$RESULT"
    fi
}

# Detect if a JavaScript interpreter is installed
#
# $1: (optional) Print flag
# stdout: path of executable (if $1 is a non empty string)
detect_javascript() {
    if ! check_exec 'js'; then
        log_notice "Javascript interpreter not found"
        return $ERR_SYSTEM
    fi
    test -n "$1" && type -P 'js'
    return 0
}

# Execute javascript code
#
# stdin: js script
# stdout: script result
javascript() {
    local JS_PRG TEMPSCRIPT

    JS_PRG=$(detect_javascript 1) || return
    TEMPSCRIPT=$(create_tempfile '.js') || return

    cat > "$TEMPSCRIPT"

    log_report "interpreter:$JS_PRG"
    log_report "=== JAVASCRIPT BEGIN ==="
    logcat_report "$TEMPSCRIPT"
    log_report "=== JAVASCRIPT END ==="

    $JS_PRG "$TEMPSCRIPT"
    rm -f "$TEMPSCRIPT"
    return 0
}

# Wait some time
# Related to -t/--timeout command line option
#
# $1: Sleep duration
# $2: Unit (seconds | minutes)
wait() {
    local VALUE=$1
    local UNIT=$2

    if test "$VALUE" = '0'; then
        log_debug "wait called with null duration"
        return
    fi

    if [ "$UNIT" = "minutes" ]; then
        UNIT_SECS=60
        UNIT_STR=minutes
    else
        UNIT_SECS=1
        UNIT_STR=seconds
    fi
    local TOTAL_SECS=$((VALUE * UNIT_SECS))

    timeout_update $TOTAL_SECS || return

    local REMAINING=$TOTAL_SECS
    local MSG="Waiting $VALUE $UNIT_STR..."
    local CLEAR="     \b\b\b\b\b"
    if test -t 2; then
      while [ "$REMAINING" -gt 0 ]; do
          log_notice -ne "\r$MSG $(splitseconds $REMAINING) left${CLEAR}"
          sleep 1
          (( --REMAINING ))
      done
      log_notice -e "\r$MSG done${CLEAR}"
    else
      log_notice "$MSG"
      sleep $TOTAL_SECS
    fi
}

# $1: local image filename (with full path). No specific image format expected.
# $2: captcha type or hint
# $3 (optional): minimal captcha length
# $4 (optional): maximal captcha length (unused)
# stdout: On 2 lines: <word> \n <transaction_id>
#         nothing is echoed in case of error
#
# Important note: input image ($1) is deleted in case of error
captcha_process() {
    local -r CAPTCHA_TYPE=$2
    local METHOD_SOLVE METHOD_VIEW FILENAME RESPONSE WORD I
    local TID=0

    if [ -f "$1" ]; then
        FILENAME=$1
    elif match_remote_url "$1"; then
        FILENAME=$(create_tempfile '.captcha') || return
        curl -o "$FILENAME" "$1" || return

        if [ ! -s "$FILENAME" ]; then
            log_error "empty file"
            return $ERR_FATAL
        fi
    else
        log_error "image file not found"
        return $ERR_FATAL
    fi

    # plowdown --captchaprogram
    if [ -n "$CAPTCHA_PROGRAM" ]; then
        local RET=0

        WORD=$(exec "$CAPTCHA_PROGRAM" "$MODULE" "$FILENAME" "${CAPTCHA_TYPE}-$3") || RET=$?
        if [ $RET -eq 0 ]; then
            echo "$WORD"
            echo $TID
            return 0
        elif [ $RET -ne $ERR_NOMODULE ]; then
            log_error "captchaprogram exit with status $RET"
            return $RET
        fi
    fi

    # plowdown --captchamethod
    if [ -n "$CAPTCHA_METHOD" ]; then
        captcha_method_translate "$CAPTCHA_METHOD" METHOD_SOLVE METHOD_VIEW
    fi

    # Auto (guess) mode
    if [ -z "$METHOD_SOLVE" ]; then
        if [ -n "$CAPTCHA_ANTIGATE" ]; then
            METHOD_SOLVE='antigate'
            METHOD_VIEW='none'
        elif [ -n "$CAPTCHA_TRADER" ]; then
            METHOD_SOLVE='captchatrader'
            METHOD_VIEW='none'
        elif [ -n "$CAPTCHA_DEATHBY" ]; then
            METHOD_SOLVE='deathbycaptcha'
            METHOD_VIEW='none'
        else
            METHOD_SOLVE=prompt
        fi
    fi

    if [ -z "$METHOD_VIEW" ]; then
        # X11 server installed ?
        if [ "$METHOD_SOLVE" != 'prompt-nox' -a -n "$DISPLAY" ]; then
            if check_exec 'display'; then
                METHOD_VIEW=X-display
            elif check_exec 'sxiv'; then
                METHOD_VIEW=X-sxiv
            elif check_exec 'qiv'; then
                METHOD_VIEW=X-qiv
            else
                log_notice "No X11 image viewer found, to display captcha image"
            fi
        fi
        if [ -z "$METHOD_VIEW" ]; then
            # libcaca
            if check_exec img2txt; then
                METHOD_VIEW=img2txt
            # terminal image view (perl script using Image::Magick)
            elif check_exec tiv; then
                METHOD_VIEW=tiv
            # libaa
            elif check_exec aview && check_exec convert; then
                METHOD_VIEW=aview
            else
                log_notice "No ascii viewer found to display captcha image"
                METHOD_VIEW=none
            fi
        fi
    fi

    # Try to maximize the image size on terminal
    local MAX_OUTPUT_WIDTH MAX_OUTPUT_HEIGHT
    if [ "$METHOD_VIEW" != 'none' -a "${METHOD_VIEW:0:1}" != 'X' ]; then
        if check_exec tput; then
            MAX_OUTPUT_WIDTH=$(tput cols)
            MAX_OUTPUT_HEIGHT=$(tput lines)
            if check_exec identify; then
                local DIMENSION=$(identify -quiet "$FILENAME" | cut -d' ' -f3)
                local W=${DIMENSION%x*}
                local H=${DIMENSION#*x}
                [ "$W" -lt "$MAX_OUTPUT_WIDTH" ] && MAX_OUTPUT_WIDTH=$W
                [ "$H" -lt "$MAX_OUTPUT_HEIGHT" ] && MAX_OUTPUT_HEIGHT=$H
            fi
        else
            MAX_OUTPUT_WIDTH=150
            MAX_OUTPUT_HEIGHT=57
        fi
    fi

    local IMG_HASH PRG_PID IMG_PNM

    # How to display image
    case "$METHOD_VIEW" in
        none)
            log_notice "Local image: $FILENAME"
            ;;
        aview)
            local -r FF=$'\f'
            # aview can only display files in PNM file format
            IMG_PNM=$(create_tempfile '.pnm') || return
            convert "$FILENAME" -negate -depth 8 pnm:$IMG_PNM && \
                aview -width $MAX_OUTPUT_WIDTH -height $MAX_OUTPUT_HEIGHT \
                    -kbddriver stdin -driver stdout "$IMG_PNM" 2>/dev/null <<<'q' | \
                        sed -e "1d;/$FF/,/$FF/d;/^[[:space:]]*$/d" 1>&2
            rm -f "$IMG_PNM"
            ;;
        tiv)
            tiv -a -w $MAX_OUTPUT_WIDTH -h $MAX_OUTPUT_HEIGHT "$FILENAME" 1>&2
            ;;
        img2txt)
            img2txt -W $MAX_OUTPUT_WIDTH -H $MAX_OUTPUT_HEIGHT "$FILENAME" 1>&2
            ;;
        X-display)
            display "$FILENAME" &
            PRG_PID=$!
            ;;
        X-qiv)
            qiv "$FILENAME" &
            PRG_PID=$!
            ;;
        X-sxiv)
            # open a 640x480 window
            sxiv -q -s "$FILENAME" &
            [ $? -eq 0 ] && PRG_PID=$!
            ;;
        imgur)
            IMG_HASH=$(image_upload_imgur "$FILENAME") || true
            ;;
        *)
            log_error "unknown view method: $METHOD_VIEW"
            rm -f "$FILENAME"
            return $ERR_FATAL
            ;;
    esac

    local TEXT1='Leave this field blank and hit enter to get another captcha image'
    local TEXT2='Enter captcha response (drop punctuation marks, case insensitive): '

    # How to solve captcha
    case "$METHOD_SOLVE" in
        none)
            rm -f "$FILENAME"
            return $ERR_CAPTCHA
            ;;
        antigate)
            if ! service_antigate_ready "$CAPTCHA_ANTIGATE"; then
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            log_notice "Using antigate captcha recognition system"

            # Note for later: extra params can be supplied: min_len & max_len
            RESPONSE=$(curl -F 'method=post' \
                -F "file=@$FILENAME;filename=file.jpg" \
                -F "key=$CAPTCHA_ANTIGATE" \
                -F 'is_russian=0' \
                'http://antigate.com/in.php') || return

            if [ -z "$RESPONSE" ]; then
                log_error "antigate empty answer"
                rm -f "$FILENAME"
                return $ERR_NETWORK
            elif [ 'ERROR_IP_NOT_ALLOWED' = "$RESPONSE" ]; then
                log_error "antigate error: IP not allowed"
                rm -f "$FILENAME"
                return $ERR_FATAL
            elif [ 'ERROR_ZERO_BALANCE' = "$RESPONSE" ]; then
                log_error "antigate error: no credits"
                rm -f "$FILENAME"
                return $ERR_FATAL
            elif [ 'ERROR_NO_SLOT_AVAILABLE' = "$RESPONSE" ]; then
                log_error "antigate error: no slot available"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            elif match 'ERROR_' "$RESPONSE"; then
                log_error "antigate error: $RESPONSE"
                rm -f "$FILENAME"
                return $ERR_FATAL
            fi

            TID=$(echo "$RESPONSE" | parse_quiet . 'OK|\(.*\)')

            for I in 8 5 5 6 6 7 7 8; do
                wait $I seconds
                RESPONSE=$(curl --get \
                    --data "key=${CAPTCHA_ANTIGATE}&action=get&id=$TID"  \
                    'http://antigate.com/res.php') || return

                if [ 'CAPCHA_NOT_READY' = "$RESPONSE" ]; then
                    continue
                elif match '^OK|' "$RESPONSE"; then
                    WORD=$(echo "$RESPONSE" | parse_quiet . 'OK|\(.*\)')
                    break
                else
                    log_error "antigate error: $RESPONSE"
                    rm -f "$FILENAME"
                    return $ERR_FATAL
                fi
            done

            if [ -z "$WORD" ]; then
                log_error "antigate error: service not unavailable"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            # result on two lines
            echo "$WORD"
            echo "a$TID"
            ;;
        captchatrader)
            local USERNAME=${CAPTCHA_TRADER%%:*}
            local PASSWORD=${CAPTCHA_TRADER#*:}

            if ! service_captchatrader_ready "$USERNAME" "$PASSWORD"; then
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            log_notice "Using captcha.trader bypass service ($USERNAME)"

            # Plowshare API key for CaptchaTrader
            RESPONSE=$(curl -F "match=" \
                -F "api_key=1645b45413c7e23a470475f33692cb63" \
                -F "password=$PASSWORD" \
                -F "username=$USERNAME" \
                -F "value=@$FILENAME;filename=file" \
                'http://api.captchatrader.com/submit') || return

            if [ -z "$RESPONSE" ]; then
                log_error "captcha.trader empty answer"
                rm -f "$FILENAME"
                return $ERR_NETWORK
            fi

            if match '503 Service Unavailable' "$RESPONSE"; then
                log_error "captcha.trader server unavailable"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            TID=$(echo "$RESPONSE" | parse_quiet . '\[\([^,]*\)')
            WORD=$(echo "$RESPONSE" | parse_quiet . ',"\([^"]*\)')

            if [ "$TID" -eq '-1' ]; then
                log_error "captcha.trader error: $WORD"
                rm -f "$FILENAME"
                if [ 'INSUFFICIENT CREDITS' = "$WORD" ]; then
                    return $ERR_FATAL
                fi
                return $ERR_CAPTCHA
            fi

            # result on two lines
            echo "$WORD"
            echo "c$TID"
            ;;
        deathbycaptcha)
            local HTTP_CODE POLL_URL
            local USERNAME=${CAPTCHA_DEATHBY%%:*}
            local PASSWORD=${CAPTCHA_DEATHBY#*:}

            if ! service_captchadeathby_ready "$USERNAME" "$PASSWORD"; then
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            log_notice "Using DeathByCaptcha service ($USERNAME)"

            # Consider HTTP headers, don't use JSON answer
            RESPONSE=$(curl --include --header 'Expect: ' \
                --header 'Accept: application/json' \
                -F "username=$USERNAME" \
                -F "password=$PASSWORD" \
                -F "captchafile=@$FILENAME" \
                'http://api.dbcapi.me/api/captcha') || return

            if [ -z "$RESPONSE" ]; then
                log_error "DeathByCaptcha empty answer"
                rm -f "$FILENAME"
                return $ERR_NETWORK
            fi

            HTTP_CODE=$(echo "$RESPONSE" | first_line | \
                parse . 'HTTP/1\.. \([[:digit:]]\+\) ')

            if [ "$HTTP_CODE" = 303 ]; then
                POLL_URL=$(echo "$RESPONSE" | grep_http_header_location) || return

                for I in 4 3 3 4 4 5 5; do
                    wait $I seconds

                    # {"status": 0, "captcha": 661085218, "is_correct": true, "text": ""}
                    RESPONSE=$(curl --header 'Accept: application/json' \
                        "$POLL_URL") || return

                    if match_json_true 'is_correct' "$RESPONSE"; then
                        WORD=$(echo "$RESPONSE" | parse_json_quiet text)
                        if [ -n "$WORD" ]; then
                            TID=$(echo "$RESPONSE" | parse_json_quiet captcha)
                            echo "$WORD"
                            echo "d$TID"
                            return 0
                        fi
                    else
                        log_error "DeathByCaptcha unknown error: $RESPONSE"
                        rm -f "$FILENAME"
                        return $ERR_CAPTCHA
                    fi
                done
                log_error "DeathByCaptcha timeout: give up!"
            else
                log_error "DeathByCaptcha wrong http answer ($HTTP_CODE)"
            fi
            rm -f "$FILENAME"
            return $ERR_CAPTCHA
            ;;
        prompt*)
            # Reload mecanism is not available for all types
            if [ "$CAPTCHA_TYPE" = 'recaptcha' -o \
                 "$CAPTCHA_TYPE" = 'solvemedia' ]; then
                log_notice "$TEXT1"
            fi

            read -p "$TEXT2" RESPONSE
            echo "$RESPONSE"
            echo $TID
            ;;
        *)
            log_error "unknown solve method: $METHOD_SOLVE"
            rm -f "$FILENAME"
            return $ERR_FATAL
            ;;
    esac

    # Second pass for cleaning up
    case "$METHOD_VIEW" in
        X-*)
            [[ $PRG_PID ]] && kill -HUP $PRG_PID 2>&1 >/dev/null
            ;;
        imgur)
            image_delete_imgur "$IMG_HASH" || true
            ;;
    esac

    # if captcha URL provided, drop temporary image file
    if [ "$1" != "$FILENAME" ]; then
        rm -f "$FILENAME"
    fi
}

# reCAPTCHA decoding function
# Main engine: http://api.recaptcha.net/js/recaptcha.js
#
# $1: reCAPTCHA site public key
# stdout: On 3 lines: <word> \n <challenge> \n <transaction_id>
recaptcha_process() {
    local -r RECAPTCHA_SERVER='http://www.google.com/recaptcha/api/'
    local URL="${RECAPTCHA_SERVER}challenge?k=${1}&ajax=1"
    local VARS SERVER TRY CHALLENGE FILENAME WORDS TID

    VARS=$(curl -L "$URL") || return

    if [ -z "$VARS" ]; then
        return $ERR_CAPTCHA
    fi

    # Load image
    SERVER=$(echo "$VARS" | parse_quiet 'server' "server[[:space:]]\?:[[:space:]]\?'\([^']*\)'") || return
    CHALLENGE=$(echo "$VARS" | parse_quiet 'challenge' "challenge[[:space:]]\?:[[:space:]]\?'\([^']*\)'") || return

    log_debug "reCaptcha server: $SERVER"

    # Image dimension: 300x57
    FILENAME=$(create_tempfile '.recaptcha.jpg') || return

    TRY=0
    # Arbitrary 100 limit is safer
    while (( TRY++ < 100 )) || return $ERR_MAX_TRIES_REACHED; do
        log_debug "reCaptcha loop $TRY"
        log_debug "reCaptcha challenge: $CHALLENGE"

        URL="${SERVER}image?c=${CHALLENGE}"

        log_debug "reCaptcha image URL: $URL"
        curl "$URL" -o "$FILENAME" || return

        WORDS=$(captcha_process "$FILENAME" recaptcha) || return
        rm -f "$FILENAME"

        { read WORDS; read TID; } <<<"$WORDS"

        [ -n "$WORDS" ] && break

        # Reload image
        log_debug "empty, request another image"

        # Result: Recaptcha.finish_reload('...', 'image');
        VARS=$(curl "${SERVER}reload?k=${1}&c=${CHALLENGE}&reason=r&type=image&lang=en") || return
        CHALLENGE=$(echo "$VARS" | parse 'finish_reload' "('\([^']*\)") || return
    done

    WORDS=$(echo "$WORDS" | uri_encode)

    echo "$WORDS"
    echo "$CHALLENGE"
    echo $TID
}

# Process captcha from "Solve Media" (http://www.solvemedia.com/)
# $1: Solvemedia site public key
# stdout: On 2 lines: <verified_challenge> \n <transaction_id>
# stdout: verified challenge
#         transaction_id
solvemedia_captcha_process() {
    local -r PUB_KEY=$1
    local -r BASE_URL='http://api.solvemedia.com/papi'
    local URL="$BASE_URL/challenge.noscript?k=$PUB_KEY"
    local HTML MAGIC CHALL IMG_FILE XY WI WORDS TID TRY

    IMG_FILE=$(create_tempfile '.solvemedia.jpg') || return

    TRY=0
    # Arbitrary 100 limit is safer
    while (( TRY++ < 100 )) || return $ERR_MAX_TRIES_REACHED; do
        log_debug "SolveMedia loop $TRY"
        XY=''

        # Get + scrape captcha iframe
        HTML=$(curl "$URL") || return
        MAGIC=$(echo "$HTML" | parse_form_input_by_name 'magic') || return
        CHALL=$(echo "$HTML" | parse_form_input_by_name \
            'adcopy_challenge') || return

        # Get actual captcha image
        curl -o "$IMG_FILE" "$BASE_URL/media?c=$CHALL" || return

        # Solve captcha
        # Note: Image is a 300x150 gif file containing text strings
        WI=$(captcha_process "$IMG_FILE" solvemedia) || return
        { read WORDS; read TID; } <<< "$WI"
        rm -f "$IMG_FILE"

        # Reload image?
        if [ -z "$WORDS" ]; then
            log_debug "empty, request another image"
            XY="-d t_img.x=23 -d t_img.y=7"
        fi

        # Verify solution/request new challenge
        HTML=$(curl --referer "$URL" \
            -d "adcopy_response=$WORDS" \
            -d "k=$PUB_KEY" \
            -d 'l=en' \
            -d 't=img' \
            -d 's=standard' \
            -d "magic=$MAGIC" \
            -d "adcopy_challenge=$CHALL" \
            $XY \
            "$BASE_URL/verify.noscript") || return

        if ! match 'Redirecting\.\.\.' "$HTML" ||
            match '&error=1&' "$HTML"; then
            captcha_nack "$TID"
            return $ERR_CAPTCHA
        fi

        URL=$(echo "$HTML" | parse 'META' 'URL=\(.\+\)">') || return

        [ -n "$WORDS" ] && break
    done

    HTML=$(curl "$URL") || return

    if ! match 'Please copy this gibberish:' "$HTML" || \
            ! match "$CHALL" "$HTML"; then
        log_debug 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    echo "$CHALL"
    echo "$TID"
}

# Positive acknowledge of captcha answer
# $1: id (given by captcha_process or recpatcha_process)
captcha_ack() {
    [ "$1" = 0 ] && return

    local M=${1:0:1}
    local TID=${1:1}
    local RESPONSE STR

    if [ a = "$M" ]; then
        :
    elif [ c = "$M" ]; then
        if [ -n "$CAPTCHA_TRADER" ]; then
            local USERNAME=${CAPTCHA_TRADER%%:*}
            local PASSWORD=${CAPTCHA_TRADER#*:}

            log_debug "captcha.trader report ack ($USERNAME)"

            RESPONSE=$(curl -F 'match=' \
                -F "is_correct=1"       \
                -F "ticket=$TID"        \
                -F "password=$PASSWORD" \
                -F "username=$USERNAME" \
                'http://api.captchatrader.com/respond') || return

            STR=$(echo "$RESPONSE" | parse_quiet . ',"\([^"]*\)')
            [ -n "$STR" ] && log_error "captcha.trader error: $STR"
        else
            log_error "$FUNCNAME failed: captcha.trader missing account data"
        fi
    elif [ d = "$M" ]; then
        :
    else
        log_error "$FUNCNAME failed: unknown transaction ID: $1"
    fi
}

# Negative acknowledge of captcha answer
# $1: id (given by captcha_process or recpatcha_process)
captcha_nack() {
    [ "$1" = 0 ] && return

    local M=${1:0:1}
    local TID=${1:1}
    local RESPONSE STR

    if [ a = "$M" ]; then
        if [ -n "$CAPTCHA_ANTIGATE" ]; then
            RESPONSE=$(curl --get \
                --data "key=${CAPTCHA_ANTIGATE}&action=reportbad&id=$TID"  \
                'http://antigate.com/res.php') || return

            [ 'OK_REPORT_RECORDED' = "$RESPONSE" ] || \
                log_error "antigate error: $RESPONSE"
        else
            log_error "$FUNCNAME failed: antigate missing captcha key"
        fi

    elif [ c = "$M" ]; then
        if [ -n "$CAPTCHA_TRADER" ]; then
            local USERNAME=${CAPTCHA_TRADER%%:*}
            local PASSWORD=${CAPTCHA_TRADER#*:}

            log_debug "captcha.trader report nack ($USERNAME)"

            RESPONSE=$(curl -F "match=" \
                -F "is_correct=0"       \
                -F "ticket=$TID"        \
                -F "password=$PASSWORD" \
                -F "username=$USERNAME" \
                'http://api.captchatrader.com/respond') || return

            STR=$(echo "$RESPONSE" | parse_quiet . ',"\([^"]*\)')
            [ -n "$STR" ] && log_error "captcha.trader error: $STR"
        else
            log_error "$FUNCNAME failed: captcha.trader missing account data"
        fi

    elif [ d = "$M" ]; then
        if [ -n "$CAPTCHA_DEATHBY" ]; then
            local USERNAME=${CAPTCHA_DEATHBY%%:*}
            local PASSWORD=${CAPTCHA_DEATHBY#*:}

            log_debug "DeathByCaptcha report nack ($USERNAME)"

            RESPONSE=$(curl \
                -F "username=$USERNAME" \
                -F "password=$PASSWORD" \
                "http://api.dbcapi.me/api/captcha/$TID/report") || return

            log_error "DeathByCaptcha: report nack FIXME[$RESPONSE]"
        else
            log_error "$FUNCNAME failed: DeathByCaptcha missing account data"
        fi

    else
        log_error "$FUNCNAME failed: unknown transaction ID: $1"
    fi
}

# Generate a pseudo-random character sequence.
# Don't use /dev/urandom or $$ but $RANDOM (internal bash builtin,
# range 0-32767). Note: chr() is from Greg's Wiki (BashFAQ/071).
#
# $1: operation type (string)
#   - "a": alpha [0-9a-z]. Param: length.
#   - "d", "dec": positive decimal number. First digit is never 0.
#                 Param: number of digits.
#   - "h", "hex": hexadecimal number. First digit is never 0. No '0x' prefix.
#                 Param: number of digits.
#   - "H": same as "h" but in uppercases
#   - "js": Math.random() equivalent (>=0 and <1).
#           It's a double: ~15.9 number of decimal digits). No param.
#   - "l": letters [a-z]. Param: length.
#   - "L": letters [A-Z]. Param: length.
#   - "ll", "LL": letters [A-Za-z]. Param: length.
#   - "u16": unsigned short (decimal) number <=65535. Example: "352".
# $2: (optional) operation parameter
random() {
    local I=0
    local LEN=${2:-8}
    local SEED=$RANDOM
    local RESULT N

    # FIXME: Adding LC_CTYPE=C in front of printf is required?

    case "$1" in
        d|dec)
            RESULT=$(( SEED % 9 + 1 ))
            (( ++I ))
            while (( I < $LEN )); do
                N=$(printf '%04u' $((RANDOM % 10000)))
                RESULT=$RESULT$N
                (( I += 4))
            done
            ;;
        h|hex)
            RESULT=$(printf '%x' $(( SEED % 15 + 1 )))
            (( ++I ))
            while (( I < $LEN )); do
                N=$(printf '%04x' $((RANDOM & 65535)))
                RESULT=$RESULT$N
                (( I += 4))
            done
            ;;
        H)
            RESULT=$(printf '%X' $(( SEED % 15 + 1 )))
            (( ++I ))
            while (( I < $LEN )); do
                N=$(printf '%04X' $((RANDOM & 65535)))
                RESULT=$RESULT$N
                (( I += 4))
            done
            ;;
        l)
            while (( I++ < $LEN )); do
                N=$(( RANDOM % 26 + 16#61))
                RESULT=$RESULT$(printf \\$(($N/64*100+$N%64/8*10+$N%8)))
            done
            ;;
        L)
            while (( I++ < $LEN )); do
                N=$(( RANDOM % 26 + 16#41))
                RESULT=$RESULT$(printf \\$(($N/64*100+$N%64/8*10+$N%8)))
            done
            ;;
        [Ll][Ll])
            while (( I++ < $LEN )); do
                N=$(( RANDOM % 52 + 16#41))
                [[ $N -gt 90 ]] && (( N += 6 ))
                RESULT=$RESULT$(printf \\$(($N/64*100+$N%64/8*10+$N%8)))
            done
            ;;
        a)
            while (( I++ < $LEN )); do
                N=$(( RANDOM % 36 + 16#30))
                [[ $N -gt 57 ]] && (( N += 39 ))
                RESULT=$RESULT$(printf \\$(($N/64*100+$N%64/8*10+$N%8)))
            done
            ;;
        js)
            LEN=$((SEED % 3 + 17))
            RESULT='0.'$((RANDOM * 69069 & 16#ffffffff))
            RESULT=$RESULT$((RANDOM * 69069 & 16#ffffffff))
            ;;
        u16)
            RESULT=$(( 256 * (SEED & 255) + (RANDOM & 255) ))
            LEN=${#RESULT}
            ;;
        *)
            log_error "$FUNCNAME: unknown operation '$1'"
            return $ERR_FATAL
            ;;
    esac
    echo ${RESULT:0:$LEN}
}

# Calculate MD5 hash (128-bit) of a string.
# See RFC1321.
#
# $1: input string
# stdout: message-digest fingerprint (32-digit hexadecimal number)
# $? zero for success or $ERR_SYSTEM
md5() {
    # GNU coreutils
    if check_exec md5sum; then
        echo -n "$1" | md5sum -b 2>/dev/null | cut -d' ' -f1
    # BSD
    elif check_exec md5; then
        "$(type -P md5)" -qs "$1"
    # OpenSSL
    elif check_exec openssl; then
        echo -n "$1" | openssl dgst -md5 | cut -d' ' -f2
    # FIXME: use javascript if requested
    else
        log_error "$FUNCNAME: cannot find md5 calculator"
        return $ERR_SYSTEM
    fi
}

# Split credentials
# $1: auth string (user:password)
# $2: variable name (user)
# $3 (optional): variable name (password)
# Note: $2 or $3 can't be named '__AUTH__' or '__STR__'
split_auth() {
    local __AUTH__=$1
    local __STR__

    if [ -z "$__AUTH__" ]; then
        log_error "$FUNCNAME: authentication string is empty"
        return $ERR_LOGIN_FAILED
    fi

    __STR__=${__AUTH__%%:*}
    if [ -z "$__STR__" ]; then
        log_error "$FUNCNAME: empty string (user)"
        return $ERR_LOGIN_FAILED
    fi

    [[ "$2" ]] && unset "$2" && eval $2=\$__STR__

    if [[ "$3" ]]; then
        # Sanity check
        if [ "$2" = "$3" ]; then
            log_error "$FUNCNAME: user and password varname must not be the same"
        else
            __STR__=${__AUTH__#*:}
            if [ -z "$__STR__" -o "$__AUTH__" = "$__STR__" ]; then
                __STR__=$(prompt_for_password) || return $ERR_LOGIN_FAILED
            fi
            unset "$3" && eval $3=\$__STR__
        fi
    fi
}

# Report list results. Only used by list module functions.
#
# $1: links list (one url per line).
# $2: (optional) name list (one filename per line)
# $?: 0 for success or $ERR_LINK_DEAD
list_submit() {
    local LINE I

    test "$1" || return $ERR_LINK_DEAD

    if test "$2"; then
        local -a LINKS NAMES

        # Note: Bash 4 has 'mapfile' builtin
        I=0
        while IFS= read -r LINE; do LINKS[I++]=$LINE; done <<< "$1"
        I=0
        while IFS= read -r LINE; do NAMES[I++]=$LINE; done <<< "$2"

        for I in "${!LINKS[@]}"; do
            echo "${LINKS[$I]}"
            echo "${NAMES[$I]}"
        done
    else
        while IFS= read -r LINE; do
            test "$LINE" || continue
            echo "$LINE"
            echo
        done <<< "$1"
    fi
}

## ----------------------------------------------------------------------------

##
## Miscellaneous functions that can be called from core:
## download.sh, upload.sh, delete.sh, list.sh
##

# Remove all temporal files created by the script
# (with create_tempfile)
remove_tempfiles() {
    rm -f "${TMPDIR:-/tmp}/$(basename_file $0).$$".*
}

# Exit callback (task: clean temporal files)
set_exit_trap() {
    trap remove_tempfiles EXIT
}

# Check existance of executable in path
# Better than "which" (external) executable
#
# $1: Executable to check
# $?: zero means not found
check_exec() {
    type -P $1 >/dev/null || return 1 && return 0
}

# Related to -t/--timeout command line option
timeout_init() {
    PS_TIMEOUT=$1
}

# Show help info for options
#
# $1: options
# $2: indent string
print_options() {
    local STR VAR SHORT LONG VALUE HELP
    local INDENT=${2:-'  '}
    while read OPTION; do
        test "$OPTION" || continue
        IFS="," read VAR SHORT LONG VALUE HELP <<< "$OPTION"
        if [ -n "$SHORT" ]; then
            if test "$VALUE"; then
                STR="-${SHORT%:} $VALUE"
                test -n "$LONG" && STR="-${SHORT%:}, --${LONG%:}=$VALUE"
            else
                STR="-${SHORT%:}"
                test -n "$LONG" && STR="$STR, --${LONG%:}"
            fi
        # long option only
        else
            if test "$VALUE"; then
                STR="    --${LONG%:}=$VALUE"
            else
                STR="    --${LONG%:}"
            fi
        fi
        printf '%-35s%s\n' "$INDENT$STR" "$HELP"
    done <<< "$1"
}

# Show usage info for modules
#
# $1: module name list (one per line)
# $2: option family name (string, example:UPLOAD)
print_module_options() {
    while read MODULE; do
        OPTIONS=$(get_module_options "$MODULE" "$2")
        if test "$OPTIONS"; then
            echo
            echo "Options for module <$MODULE>:"
            echo
            print_options "$OPTIONS"
        fi
    done <<< "$1"
}

# Get all modules options with specified family name.
# Note: All lines are prefix with "!" character.
#
# $1: module name list (one per line)
# $2: option family name (string, example:UPLOAD)
get_all_modules_options() {
    while read MODULE; do
        get_module_options "$MODULE" "$2" | while read OPTION; do
            if test "$OPTION"; then echo "!$OPTION"; fi
        done
    done <<< "$1"
}

# Get module name from URL link
#
# $1: url
# $2: module name list (one per line)
get_module() {
    while read MODULE; do
        local VAR="MODULE_$(uppercase "$MODULE")_REGEXP_URL"
        if match "${!VAR}" "$1"; then
            echo $MODULE
            break
        fi
    done <<< "$2"
    return 0
}

# Straighforward options and arguments processing using getopt style
# $1: program name (used for error message printing)
# $2: command-line arguments list
#
# Example:
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

    local SHORT_OPTS LONG_OPTS

    # Strip spaces in options
    OPTIONS=$(echo "$OPTIONS" | strip | drop_empty_lines)

    if [ -n "$OPTIONS" ]; then
        while read VAR; do
            if test "${VAR:0:1}" = "!"; then
                VAR=${VAR:1}
            fi
            # faster than `cut -d',' -f1`
            unset "${VAR%%,*}"
        done <<< "$OPTIONS"

        SHORT_OPTS=$(echo "$OPTIONS" | cut -d',' -f2)
        LONG_OPTS=$(echo "$OPTIONS" | cut -d',' -f3)
    fi

    # Even if function is called from a module which has no option,
    # getopt must be called to detect non existant options (like -a user:password)
    local ARGUMENTS=$(getopt -o "$SHORT_OPTS" --long "$LONG_OPTS" -n "$NAME" -- "$@")

    # To correctly process whitespace and quotes.
    eval set -- "$ARGUMENTS"

    local -a UNUSED_OPTIONS=()
    while :; do
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

                    test -z "$VALUE" && \
                        stderr "process_options ($VAR): VALUE should not be empty!"

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

# Get module list according to capability
# Note1: use global variable LIBDIR
# Note2: VERBOSE (log_debug) not initialised yet
#
# $1: keyword to grep (must not contain '|' char)
# stdout: return module list (one name per line)
grep_list_modules() {
   local CONFIG="$LIBDIR/modules/config"

   if [ ! -f "$CONFIG" ]; then
       stderr "can't find config file"
       return $ERR_SYSTEM
   fi

   sed -ne "/^[^#].*|[[:space:]]*$1[[:space:]]*|/p" "$CONFIG" | \
       cut -d'|' -f1 | strip
}

# $1: section name in ini-style file ("General" will be considered too)
# $2: command-line arguments list
# Note: VERBOSE (log_debug) not initialised yet
process_configfile_options() {
    local CONFIG OPTIONS SECTION LINE NAME VALUE OPTION

    CONFIG="$HOME/.config/plowshare/plowshare.conf"
    test ! -f "$CONFIG" && CONFIG='/etc/plowshare.conf'
    test -f "$CONFIG" || return 0

    # Strip spaces in options
    OPTIONS=$(echo "$2" | strip | drop_empty_lines)

    SECTION=$(sed -ne "/\[$1\]/,/^\[/p" -ne "/\[General\]/,/^\[/p" "$CONFIG" | \
              sed -e '/^\(#\|\[\|[[:space:]]*$\)/d')

    if [ -n "$SECTION" -a -n "$OPTIONS" ]; then
        while read LINE; do
            NAME=$(echo "${LINE%%=*}" | strip)
            VALUE=$(echo "${LINE#*=}" | strip)

            # Look for optional double quote (protect leading/trailing spaces)
            if [ '"' = "${VALUE:0:1}" -a '"' = "${VALUE:(-1):1}" ]; then
                VALUE=${VALUE%?}
                VALUE=${VALUE:1}
            fi

            # Look for 'long_name' in options list
            OPTION=$(echo "$OPTIONS" | grep ",${NAME}:\?," | sed '1q') || true
            if [ -n "$OPTION" ]; then
                local VAR=${OPTION%%,*}
                eval "$VAR=\$VALUE"
            fi
        done <<< "$SECTION"
    fi
}

# $1: section name in ini-style file ("General" will be considered too)
# $2: module name
# $3: option family name (string, example:DOWNLOAD)
process_configfile_module_options() {
    local CONFIG OPTIONS SECTION OPTION LINE VALUE

    CONFIG="$HOME/.config/plowshare/plowshare.conf"
    if [ -f "$CONFIG" ]; then
        if [ -O "$CONFIG" ]; then
            local FILE_PERM=$(stat -c %A "$CONFIG")
            test -z "$FILE_PERM" && FILE_PERM=$(ls -l "$CONFIG" | cut -b1-10)
            if [[ ${FILE_PERM:4:6} != '------' ]]; then
                log_notice "Warning (configuration file permissions): chmod 600 $CONFIG"
            fi
        else
            log_notice "Warning (configuration file ownership): chown $USERNAME $CONFIG"
        fi
    else
        CONFIG='/etc/plowshare.conf'
        test -f "$CONFIG" || return 0
    fi

    log_report "use $CONFIG"

    # Strip spaces in options
    OPTIONS=$(get_module_options "$2" "$3" | strip | drop_empty_lines)

    SECTION=$(sed -ne "/\[$1\]/,/^\[/p" -ne "/\[General\]/,/^\[/p" "$CONFIG" | \
              sed -e '/^\(#\|\[\|[[:space:]]*$\)/d')

    if [ -n "$SECTION" -a -n "$OPTIONS" ]; then
        local M=$(lowercase "$2")

        # For example:
        # AUTH,a:,auth:,USER:PASSWORD,Free or Premium account"
        while read OPTION; do
            IFS="," read VAR SHORT LONG VALUE_HELP <<< "$OPTION"
            SHORT=${SHORT%:}
            LONG=${LONG%:}

            # Look for 'module/option_name' (short or long) in section list
            LINE=$(echo "$SECTION" | grep "^$M/\($SHORT\|$LONG\)[[:space:]]*=" | sed -n '$p') || true
            if [ -n "$LINE" ]; then
                VALUE=$(echo "${LINE#*=}" | strip)

                # Look for optional double quote (protect leading/trailing spaces)
                if [ '"' = "${VALUE:0:1}" -a '"' = "${VALUE:(-1):1}" ]; then
                    VALUE=${VALUE%?}
                    VALUE=${VALUE:1}
                fi

                eval "$VAR=\$VALUE"
                log_notice "$M: take --$LONG option from configuration file"
            else
                unset "$VAR"
            fi
        done <<< "$OPTIONS"
    fi
}

# Get system information
log_report_info() {
    local G

    if test $(verbose_level) -ge 4; then
        log_report '=== SYSTEM INFO BEGIN ==='
        log_report "[mach] $(uname -a)"
        log_report "[bash] $BASH_VERSION"
        test "$http_proxy" && log_report "[env ] http_proxy=$http_proxy"
        if check_exec 'curl'; then
            log_report "[curl] $("$(type -P curl)" --version | first_line)"
        else
            log_report '[curl] not found!'
        fi
        check_exec 'gsed' && G=g
        log_report "[sed ] $("$(type -P ${G}sed)" --version | sed -ne '/version/p')"
        log_report '=== SYSTEM INFO END ==='
    fi
}

# Translate plowdown --captchamethod argument
# to solve & view method (used by captcha_process)
# $1: method (string)
# $2 (optional): solve method (variable name)
# $3 (optional): display method (variable name)
captcha_method_translate() {
    case "$1" in
        none)
            [[ $2 ]] && unset "$2" && eval $2=none
            [[ $3 ]] && unset "$3" && eval $3=none
            ;;
        imgur)
            [[ $2 ]] && unset "$2" && eval $2=prompt
            [[ $3 ]] && unset "$3" && eval $3=imgur
            ;;
        prompt)
            [[ $2 ]] && unset "$2" && eval $2=$1
            [[ $3 ]] && unset "$3" && eval $3=""
            ;;
        nox)
            [[ $2 ]] && unset "$2" && eval $2=prompt-nox
            [[ $3 ]] && unset "$3" && eval $3=""
            ;;
        online)
            local SITE
            if [ -n "$CAPTCHA_ANTIGATE" ]; then
                SITE=antigate
            elif [ -n "$CAPTCHA_TRADER" ]; then
                SITE=captchatrader
            elif [ -n "$CAPTCHA_DEATHBY" ]; then
                SITE=deathbycaptcha
            else
                log_error "Error: no captcha solver account provided"
                return $ERR_FATAL
            fi
            [[ $2 ]] && unset "$2" && eval $2=$SITE
            [[ $3 ]] && unset "$3" && eval $3=none
            ;;
        *)
            log_error "Error: unknown captcha method: $1"
            return $ERR_FATAL
            ;;
    esac
    return 0
}

## ----------------------------------------------------------------------------

##
## Private ('static') functions
## Can be called from this script only.
##

verbose_level() {
    echo ${VERBOSE:-0}
}

stderr() {
    echo "$@" >&2
}

quote() {
    for ARG in "$@"; do
        echo -n "$(declare -p ARG | sed "s/^declare -- ARG=//") "
    done | sed "s/ $//"
}

# Delete blank lines
# stdin: input (multiline) string
# stdout: result string
drop_empty_lines() {
    sed -e '/^[[:space:]]*$/d'
}

# Look for a configuration module variable
# Example: MODULE_4SHARED_DOWNLOAD_OPTIONS (result can be multiline)
# $1: module name
# $2: option family name (string, example:UPLOAD)
# stdout: options list (one per line)
get_module_options() {
    local VAR="MODULE_$(uppercase "$1")_${2}_OPTIONS"
    echo "${!VAR}"
}

# Example: 12345 => "3h25m45s"
# $1: duration (integer)
splitseconds() {
    local DIV_H=$(( $1 / 3600 ))
    local DIV_M=$(( ($1 % 3600) / 60 ))
    local DIV_S=$(( $1 % 60 ))

    [ "$DIV_H" -eq 0 ] || echo -n "${DIV_H}h"
    [ "$DIV_M" -eq 0 ] || echo -n "${DIV_M}m"
    [ "$DIV_S" -eq 0 ] && echo || echo "${DIV_S}s"
}

# Called by wait
# See also timeout_init()
timeout_update() {
    local WAIT=$1
    test -z "$PS_TIMEOUT" && return
    log_debug "time left to timeout: $PS_TIMEOUT secs"
    if [[ $PS_TIMEOUT -lt $WAIT ]]; then
        log_notice "Timeout reached (asked to wait $WAIT seconds, but remaining time is $PS_TIMEOUT)"
        return $ERR_MAX_WAIT_REACHED
    fi
    (( PS_TIMEOUT -= WAIT ))
}

# Look for one element in a array
# $1: array[@]
# $2: element to find
# $3: alternate element to find (can be null)
# $?: 0 for success (one element found), not found otherwise
find_in_array() {
    for ELT in "${!1}"; do
        [ "$ELT" = "$2" -o "$ELT" = "$3" ] && return 0
    done
    return 1
}

# Find next array index of one element
# $1: array[@]
# $2: element to find
# $3: alternate element to find (can be null)
# $?: 0 for success (one element found), not found otherwise
# stdout: array index, undefined if not found.
index_in_array() {
    local I=0
    for ELT in "${!1}"; do
        (( ++I ))
        if [ "$ELT" = "$2" -o "$ELT" = "$3" ]; then
            # Note: assume that it is not last element
            echo "$I"
            return 0
        fi
    done
    return 1
}

# Verify balance (captcha.trader)
# $1: captcha trader username
# $2: captcha trader password (or passkey)
# $?: 0 for success (enough credits)
service_captchatrader_ready() {
    local USER=$1
    local RESPONSE STATUS AMOUNT ERROR

    if [ -z "$1" -o -z "$2" ]; then
        log_error "captcha.trader missing account data"
        return $ERR_FATAL
    fi

    RESPONSE=$(curl "http://api.captchatrader.com/get_credits/$USER/$2") || { \
        log_notice "captcha.trader: site seems to be down"
        return $ERR_NETWORK
    }

    STATUS=$(echo "$RESPONSE" | parse_quiet . '\[\([^,]*\)')
    if [ "$STATUS" = '0' ]; then
        AMOUNT=$(echo "$RESPONSE" | parse_quiet . ',[[:space:]]*\([[:digit:]]\+\)')
        if [[ $AMOUNT -lt 10 ]]; then
            log_notice "captcha.trader: not enough credits ($USER)"
            return $ERR_FATAL
        fi
    else
        ERROR=$(echo "$RESPONSE" | parse_quiet . ',"\([^"]*\)')
        log_error "captcha.trader error: $ERROR"
        return $ERR_FATAL
    fi

    log_debug "captcha.trader credits: $AMOUNT"
}

# Verify balance (antigate)
# $1: antigate.com captcha key
# $?: 0 for success (enough credits)
service_antigate_ready() {
    local KEY=$1
    local AMOUNT

    if [ -z "$KEY" ]; then
        log_error "antigate: missing captcha key"
        return $ERR_FATAL
    fi

    AMOUNT=$(curl --get --data "key=${CAPTCHA_ANTIGATE}&action=getbalance" \
        'http://antigate.com/res.php') || { \
        log_notice "antigate: site seems to be down"
        return $ERR_NETWORK
    }

    if match '500 Internal Server Error' "$AMOUNT"; then
        log_error "antigate: internal server error (HTTP 500)"
        return $ERR_CAPTCHA
    elif match '502 Bad Gateway' "$AMOUNT"; then
        log_error "antigate: bad gateway (HTTP 502)"
        return $ERR_CAPTCHA
    elif match '503 Service Unavailable' "$AMOUNT"; then
        log_error "antigate: service unavailable (HTTP 503)"
        return $ERR_CAPTCHA
    elif match '^ERROR' "$AMOUNT"; then
        log_error "antigate error: $AMOUNT"
        return $ERR_FATAL
    elif [ '0.0000' = "$AMOUNT" -o '-' = "${AMOUNT:0:1}" ]; then
        log_notice "antigate: no more credits (or bad key)"
        return $ERR_FATAL
    else
        log_debug "antigate credits: \$$AMOUNT"
    fi
}

# Verify balance (DeathByCaptcha)
# $1: death by captcha username
# $2: death by captcha password
# $?: 0 for success (enough credits)
service_captchadeathby_ready() {
    local USER=$1
    local JSON STATUS AMOUNT ERROR

    if [ -z "$1" -o -z "$2" ]; then
        log_error "DeathByCaptcha missing account data"
        return $ERR_FATAL
    fi

    JSON=$(curl -F "username=$USER" -F "password=$2" \
            --header 'Accept: application/json' \
            'http://api.dbcapi.me/api/user') || { \
        log_notice "DeathByCaptcha: site seems to be down"
        return $ERR_NETWORK
    }

    STATUS=$(echo "$JSON" | parse_json_quiet 'status')

    if [ "$STATUS" = 0 ]; then
        AMOUNT=$(echo "$JSON" | parse_json 'balance')

        if match_json_true 'is_banned' "$JSON"; then
            log_error "DeathByCaptcha error: $USER is banned"
            return $ERR_FATAL
        fi

        if [ "${AMOUNT%.*}" = 0 ]; then
            log_notice "DeathByCaptcha: not enough credits ($USER)"
            return $ERR_FATAL
        fi
    elif [ "$STATUS" = 255 ]; then
        ERROR=$(echo "$JSON" | parse_json_quiet 'error')
        log_error "DeathByCaptcha error: $ERROR"
        return $ERR_FATAL
    else
        log_error "DeathByCaptcha unknown error: $JSON"
        return $ERR_FATAL
    fi

    log_debug "DeathByCaptcha credits: $AMOUNT"
}

# Upload (captcha) image to Imgur (picture hosting service)
# Using official API: http://api.imgur.com/
# $1: image filename (with full path)
# stdout: delete url
# $?: 0 for success
image_upload_imgur() {
    local IMG=$1
    local BASE_API='http://api.imgur.com/2'
    local RESPONSE DIRECT_URL SITE_URL DEL_HASH

    log_debug "uploading image to Imgur.com"

    # Plowshare API key for Imgur
    RESPONSE=$(curl -F "image=@$IMG" -H 'Expect: ' \
        --form-string 'key=23d202e580c2f8f378bd2852916d8f30' \
        --form-string 'type=file' \
        --form-string 'title=Plowshare uploaded image' \
        "$BASE_API/upload.json") || return

    DIRECT_URL=$(echo "$RESPONSE" | parse_json_quiet original)
    SITE_URL=$(echo "$RESPONSE" | parse_json_quiet imgur_page)
    DEL_HASH=$(echo "$RESPONSE" | parse_json_quiet deletehash)

    if [ -z "$DIRECT_URL" -o -z "$SITE_URL" ]; then
        if match '504 Gateway Time-out' "$RESPONSE"; then
            log_error "$FUNCNAME: upload error (Gateway Time-out)"
        # <h1>Imgur is over capacity!</h1>
        elif match 'Imgur is over capacity' "$RESPONSE"; then
            log_error "$FUNCNAME: upload error (Service Unavailable)"
        else
            log_error "$FUNCNAME: upload error"
        fi
        return $ERR_FATAL
    fi

    log_error "Image: $DIRECT_URL"
    log_error "Image: $SITE_URL"
    echo "$DEL_HASH"
}

# Delete (captcha) image from Imgur (picture hosting service)
# $1: delete hash
image_delete_imgur() {
    local HID=$1
    local BASE_API='http://api.imgur.com/2'
    local RESPONSE MSG

    log_debug "deleting image from Imgur.com"
    RESPONSE=$(curl "$BASE_API/delete/$HID.json") || return
    MSG=$(echo "$RESPONSE" | parse_json_quiet message)
    if [ "$MSG" != 'Success' ]; then
        log_notice "$FUNCNAME: remote error, $MSG"
    fi
}

# Some debug information
log_notice_stack() {
    local N=
    for N in "${!FUNCNAME[@]}"; do
        [ "$N" -le 1 ] && continue
        log_notice "failed inside ${FUNCNAME[$N]}(), line ${BASH_LINENO[$((N-1))]}, $(basename_file "${BASH_SOURCE[$N]}")"
        # quit if we go outside core.sh
        match '/core\.sh' "${BASH_SOURCE[$N]}" || break
    done
}
