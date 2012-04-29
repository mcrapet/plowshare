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

set -o pipefail

# Global error codes
# 0 means success or link alive
ERR_FATAL=1                      # Unexpected result (upstream site updated, etc)
ERR_NOMODULE=2                   # No module found for processing request
ERR_NETWORK=3                    # Generic network error (socket reset, curl, etc)
ERR_LOGIN_FAILED=4               # Correct login/password argument is required
ERR_MAX_WAIT_REACHED=5           # Wait timeout (see -t/--timeout command line option)
ERR_MAX_TRIES_REACHED=6          # Max tries reached (see -r/--max-retries command line option)
ERR_CAPTCHA=7                    # Captcha solving failure
ERR_SYSTEM=8                     # System failure (missing executable, local filesystem, wrong behavior, etc)
ERR_LINK_TEMP_UNAVAILABLE=10     # Link alive but temporarily unavailable
                                 # (also refer to plowdown --no-extra-wait command line option)
ERR_LINK_PASSWORD_REQUIRED=11    # Link alive but requires a password
ERR_LINK_NEED_PERMISSIONS=12     # Link alive but requires some authentication (private or premium link)
                                 # plowdel/plowup: operation not allowed for anonymous users
ERR_LINK_DEAD=13                 # plowdel: file not found or previously deleted
                                 # plowlist: remote folder does not exist or is empty
ERR_FATAL_MULTIPLE=100           # 100 + (n) with n = first error code (when multiple arguments)

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
#
# Global variables defined here:
#   - PS_TIMEOUT       Timeout (in seconds) for one URL download
#   - RECAPTCHA_SERVER Server URL (defined below)
#
# Logs are sent to stderr stream.
# Policies:
# - error: modules errors (when return 1), lastest plowdown curl call
# - notice: core messages (ocr, wait, timeout, retries), lastest plowdown curl call
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
    local -a OPTIONS=(--insecure --speed-time 600 --connect-timeout 240 "$@")
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

    # no verbose unless debug level; don't show progress meter for report level too
    test $(verbose_level) -ne 3 && OPTIONS[${#OPTIONS[@]}]='--silent'

    test -n "$NO_CURLRC" && OPTIONS=('-q' "${OPTIONS[@]}")
    test -n "$INTERFACE" && OPTIONS=("${OPTIONS[@]}" '--interface' "$INTERFACE")

    if test -n "$MAX_LIMIT_RATE"; then
        OPTIONS[${#OPTIONS[@]}]='--limit-rate'
        OPTIONS[${#OPTIONS[@]}]="$MAX_LIMIT_RATE"
    fi
    if test -n "$MIN_LIMIT_RATE"; then
        OPTIONS[${#OPTIONS[@]}]='--speed-time'
        OPTIONS[${#OPTIONS[@]}]=30
        OPTIONS[${#OPTIONS[@]}]='--speed-limit'
        OPTIONS[${#OPTIONS[@]}]="$MIN_LIMIT_RATE"
    fi

    if test $(verbose_level) -lt 4; then
        $(type -P curl) "${OPTIONS[@]}" || DRETVAL=$?
    else
        local TEMPCURL=$(create_tempfile)
        log_report "${OPTIONS[@]}"
        $(type -P curl) --show-error "${OPTIONS[@]}" 2>&1 | tee "$TEMPCURL" || DRETVAL=$?
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
            if [ -f "$F" -a ! -s "$F" ]; then
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
# stdin: text data
# stdout: result
parse_all() {
    local STRING REGEXP

    if [ '^' = "${2:0:1}" ]; then
        if [ '$' = "${2:(-1):1}" ]; then
            REGEXP="$2"
        else
            REGEXP="$2.*$"
        fi
    elif [ '$' = "${2:(-1):1}" ]; then
            REGEXP="^.*$2"
    else
            REGEXP="^.*$2.*$"
    fi

    STRING=$(sed -n "/$1/s/$REGEXP/\1/p")
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

# Get lines that first filter regex, then apply match regex on the line after.
#
# $1: regexp to filter (take lines matching $1 pattern)
# $2: regexp to match (on the lines after filter)
# stdin: text data
# stdout: result
parse_line_after_all() {
    local STRING REGEXP

    if [ '^' = "${2:0:1}" ]; then
        if [ '$' = "${2:(-1):1}" ]; then
            REGEXP="$2"
        else
            REGEXP="$2.*$"
        fi
    elif [ '$' = "${2:(-1):1}" ]; then
            REGEXP="^.*$2"
    else
            REGEXP="^.*$2.*$"
    fi

    STRING=$(sed -n "/$1/{n;s/$REGEXP/\1/p}")
    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"/$1/{n;s/$REGEXP/}\""
        log_notice_stack
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Like parse_line_after_all, but get only first match
parse_line_after() {
    parse_line_after_all "$@" | head -n1
}

# Grep "Xxx" HTTP header. Can be:
# - Location
# - Content-Location
# - Content-Type
# Note: This is using parse_all, so result can be multiline
#       (rare usage: curl -I -L ...).
#
# stdin: result of curl request (with -i/--include, -D/--dump-header
#        or -I/--head flag)
# stdout: result
grep_http_header_location() {
    parse_all '^[Ll]ocation:' 'n:[[:space:]]\+\(.*\)\r$'
}
grep_http_header_location_quiet() {
    parse_all '^[Ll]ocation:' 'n:[[:space:]]\+\(.*\)\r$' 2>/dev/null
    return 0
}
grep_http_header_content_location() {
    parse_all '^[Cc]ontent-[Ll]ocation:' 'n:[[:space:]]\+\(.*\)\r$'
}
grep_http_header_content_type() {
    parse_all '^[Cc]ontent-[Tt]ype:' 'e:[[:space:]]\+\(.*\)\r$'
}

# Grep "Content-Disposition" HTTP header
#
# stdin: HTTP response headers (see below)
# stdout: attachement filename
grep_http_header_content_disposition() {
    parse_all '^[Cc]ontent-[Dd]isposition:' 'filename="\(.*\)"'
}

# Extract a specific form from a HTML content.
# Notes:
# - start marker <form> and end marker </form> must be on separate lines
# - HTML comments are just ignored
#
# $1: (X)HTML data
# $2: (optional) Nth <form> (default is 1)
# stdout: result
grep_form_by_order() {
    local N=${2:-'1'}
    local DATA=$1

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
    local A=${2:-'.*'}
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
# $1: regexp to filter (take lines matching $1 pattern)
# $2: tag name. Example: "span".
# stdin: (X)HTML data
# stdout: result
parse_all_tag() {
    local T=${2:-"$1"}
    local STRING=$(sed -ne "/$1/s/<\/$T>.*$//p" | \
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
# $1: regexp to filter (take lines matching $1 pattern)
# $2: attribute name. Example: "href".
# stdin: (X)HTML data
# stdout: result
parse_all_attr() {
    local A=${2:-"$1"}
    local STRING=$(sed \
        -ne "/$1/s/.*$A[[:space:]]*=[[:space:]]*[\"']\([^\"'>]*\).*/\1/p" \
        -ne "/$1/s/.*$A[[:space:]]*=[[:space:]]*\([^\"'<=> 	]\+\).*/\1/p")

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
    parse_quiet "<input\([[:space:]]*[^ ]*\)*name=[\"']\?$1[\"']\?" "value=[\"']\?\([^'\">]*\)"
}

# Retrieve "value" attribute from an <input> marker with "type" attribute
# Note: "value" attribute must be placed after "type" attribute.
#
# $1: type attribute of <input> marker (for example: "submit")
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_type() {
    parse_quiet "<input\([[:space:]]*[^ ]*\)*type=[\"']\?$1[\"']\?" "value=[\"']\?\([^'\">]*\)"
}

# Retrieve "value" attribute from an <input> marker with "id" attribute
# Note: "value" attribute must be placed after "id" attribute.
#
# $1: id attribute of <input> marker
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_id() {
    parse_quiet "<input\([[:space:]]*[^ ]*\)*id=[\"']\?$1[\"']\?" "value=[\"']\?\([^'\">]*\)"
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
# Example: http://www.host.com/a/b/c/d => http://www.host.com
# Note: Avoid using Bash regexp or `expr` for portability purposes
#
# $1: URL
basename_url() {
    sed -e 's/\(https\?:\/\/[^\/]*\).*/\1/' <<<"$1"
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
        log_report "html_to_utf8: use recode"
        recode html..utf8
    elif check_exec 'perl'; then
        log_report "html_to_utf8: use perl"
        $(type -P perl) -n -mHTML::Entities \
            -e 'BEGIN { eval { binmode(STDOUT,q[:utf8]); }; } \
                print HTML::Entities::decode_entities($_);' 2>/dev/null || { \
            log_debug "html_to_utf8: perl failed, ignoring (HTML::Entities missing?)";
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
    local SIZE=$(stat -c %s "$1" 2>/dev/null)
    if [ -z "$SIZE" ]; then
        log_error "stat binary not found"
        echo "-1"
    else
        echo "$SIZE"
    fi
}

# Create a tempfile and return path
# Note for later: use mktemp (GNU coreutils)
#
# $1: Suffix
create_tempfile() {
    SUFFIX=$1
    FILE="${TMPDIR:-/tmp}/$(basename_file "$0").$$.$RANDOM$SUFFIX"
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
    read -s -r -p "Enter password: " PASSWORD

    # Add missing trailing newline (see read -p)
    stderr

    echo "$PASSWORD"
    test -n "$PASSWORD" || return $ERR_LINK_PASSWORD_REQUIRED
}

# Login and return cookie.
# A non empty cookie file does not means that login is successful.
#
# $1: String 'username:password' (password can contain semicolons)
# $2: Cookie filename (see create_tempfile() modules)
# $3: Postdata string (ex: 'user=$USER&password=$PASSWORD')
# $4: URL to post
# $5: Additional curl arguments (optional)
# stdout: html result (can be null string)
# $? is zero on success
post_login() {
    local AUTH=$1
    local COOKIE=$2
    local POSTDATA=$3
    local LOGINURL=$4
    local CURL_ARGS=$5
    local USER PASSWORD DATA RESULT

    if [ -z "$AUTH" ]; then
        log_error "Authentication string is empty"
        return $ERR_LOGIN_FAILED
    fi

    if [ -z "$COOKIE" ]; then
        log_error "Cookie file expected"
        return $ERR_LOGIN_FAILED
    fi

    # Seem faster than
    # IFS=":" read USER PASSWORD <<< "$AUTH"
    USER=$(echo "${AUTH%%:*}" | uri_encode_strict)
    PASSWORD=$(echo "${AUTH#*:}" | uri_encode_strict)

    if [ -z "$PASSWORD" -o "$AUTH" = "$PASSWORD" ]; then
        PASSWORD=$(prompt_for_password) || true
    fi

    log_notice "Starting login process: $USER/${PASSWORD//?/*}"

    DATA=$(eval echo "${POSTDATA//&/\\&}")

    # Yes, no quote around $CURL_ARGS
    RESULT=$(curl --cookie-jar "$COOKIE" --data "$DATA" $CURL_ARGS "$LOGINURL") || return

    # "$RESULT" can be empty, this is not necessarily an error
    if [ ! -s "$COOKIE" ]; then
        log_debug "post_login failed"
        return $ERR_LOGIN_FAILED
    fi

    log_report "=== COOKIE BEGIN ==="
    logcat_report "$COOKIE"
    log_report "=== COOKIE END ==="

    echo "$RESULT"
    return 0
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

    cat > $TEMPSCRIPT

    log_report "interpreter:$JS_PRG"
    log_report "=== JAVASCRIPT BEGIN ==="
    logcat_report "$TEMPSCRIPT"
    log_report "=== JAVASCRIPT END ==="

    $JS_PRG "$TEMPSCRIPT"
    rm -f "$TEMPSCRIPT"
    return 0
}

# Detect if a Perl interpreter is installed
#
# $1: (optional) Print flag
# stdout: path of executable (if $1 is a non empty string)
detect_perl() {
    if ! check_exec 'perl'; then
        log_notice "Perl interpreter not found"
        return $ERR_SYSTEM
    fi
    test -n "$1" && type -P 'perl'
    return 0
}

# Launch perl script
#
# $1: perl script filename
# $2..$n: optional script arguments
# stdout: script result
perl() {
    local PERL_PRG FILE

    PERL_PRG=$(detect_perl 1) || return
    FILE="$LIBDIR/$1"

    log_report "interpreter:$PERL_PRG"

    if [ ! -f "$FILE" ]; then
        log_error "Can't find perl script: $FILE"
        return $ERR_SYSTEM
    fi

    shift 1
    $PERL_PRG "$FILE" "$@"
}

# Wait some time
# Related to --timeout plowdown command line option
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
# $2 (optional): solve method
# $3 (optional): view method (null string means autodetect)
# stdout: On 2 lines: <word> \n <transaction_id>
#         nothing is echoed in case of error
#
# Important note: input image ($1) is deleted in case of error
captcha_process() {
    local METHOD_SOLVE=$2
    local METHOD_VIEW=$3
    local FILENAME

    if [ -f "$1" ]; then
        FILENAME=$1
    elif match_remote_url "$1"; then
        FILENAME=$(create_tempfile '.captcha') || return
        curl -o "$FILENAME" "$1" || { \
            rm -f "$FILENAME";
            return $ERR_NETWORK;
        }
    else
        log_error "image file not found"
        return $ERR_FATAL
    fi

    # plowdown --captchamethod
    if [ -n "$CAPTCHA_METHOD" ]; then
        captcha_method_translate "$CAPTCHA_METHOD" METHOD_SOLVE METHOD_VIEW
    fi

    if [ "${METHOD_SOLVE:0:3}" = 'ocr' ]; then
        if ! check_exec 'tesseract'; then
            log_notice "tesseract was not found, look for alternative solving method"
            METHOD_SOLVE=
        fi
    fi

    # Auto (guess) mode
    if [ -z "$METHOD_SOLVE" ]; then
        if [ -n "$CAPTCHA_ANTIGATE" ]; then
            METHOD_SOLVE='antigate'
            METHOD_VIEW='none'
        elif [ -n "$CAPTCHA_TRADER" ]; then
            METHOD_SOLVE='captchatrader'
            METHOD_VIEW='none'
        else
            METHOD_SOLVE=prompt
        fi
    fi

    if [ -z "$METHOD_VIEW" ]; then
        if [ "${METHOD_SOLVE:0:3}" = 'ocr' ]; then
            METHOD_VIEW=none
        # X11 server installed ?
        elif [ -n "$DISPLAY" ]; then
            if check_exec 'display'; then
                METHOD_VIEW=Xdisplay
            else
                log_notice "no X11 image viewer found, to display captcha image"
            fi
        fi
        if [ -z "$METHOD_VIEW" ]; then
            log_notice "no X server available, try ascii display"
            # libcaca
            if check_exec img2txt; then
                METHOD_VIEW=img2txt
            # terminal image view (perl script using Image::Magick)
            elif check_exec tiv; then
                METHOD_VIEW=tiv
            # libaa
            elif check_exec aview; then
                METHOD_VIEW=aview
            else
                log_notice "no ascii viewer found to display captcha image"
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

    local PRGPID=

    # How to display image
    case "$METHOD_VIEW" in
        none)
            log_notice "image: $FILENAME"
            ;;
        aview)
            # aview can only display files in PNM file format
            local IMG_PNM=$(create_tempfile '.pnm')
            convert "$FILENAME" -negate -depth 8 pnm:$IMG_PNM
            aview -width $MAX_OUTPUT_WIDTH -height $MAX_OUTPUT_HEIGHT \
                -kbddriver stdin -driver stdout "$IMG_PNM" 2>/dev/null <<<'q' | \
                sed  -e '1d;/\f/,/\f/d' | sed -e '/^[[:space:]]*$/d' 1>&2
            rm -f "$IMG_PNM"
            ;;
        tiv)
            tiv -a -w $MAX_OUTPUT_WIDTH -h $MAX_OUTPUT_HEIGHT "$FILENAME" 1>&2
            ;;
        img2txt)
            img2txt -W $MAX_OUTPUT_WIDTH -H $MAX_OUTPUT_HEIGHT "$FILENAME" 1>&2
            ;;
        Xdisplay)
            display "$FILENAME" &
            PRGPID=$!
            ;;
        *)
            log_error "unknown view method: $METHOD_VIEW"
            rm -f "$FILENAME"
            return $ERR_CAPTCHA
            ;;
    esac

    local RESPONSE
    local TID=0
    local TEXT1='Leave this field blank and hit enter to get another captcha image'
    local TEXT2='Enter captcha response (drop punctuation marks, case insensitive): '

    # How to solve captcha
    case "$METHOD_SOLVE" in
        none)
            [ -n "$PRGPID" ] && log_debug "PID $PRGPID should be killed"
            rm -f "$FILENAME"
            return $ERR_CAPTCHA
            ;;
        antigate)
            if ! captcha_antigate_ready "$CAPTCHA_ANTIGATE"; then
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            log_notice "Using antigate captcha recognition system"

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
            elif match 'ERROR_' "$RESPONSE"; then
                log_error "antigate error: $RESPONSE"
                rm -f "$FILENAME"
                return $ERR_FATAL
            fi

            local I WORD
            TID=$(echo "$RESPONSE" | parse_quiet '.' 'OK|\(.*\)')

            for I in 8 5 5 6 6 7 7 8; do
                wait $I seconds
                RESPONSE=$(curl --get \
                    --data "key=${CAPTCHA_ANTIGATE}&action=get&id=$TID"  \
                    'http://antigate.com/res.php') || return

                if [ 'CAPCHA_NOT_READY' = "$RESPONSE" ]; then
                    continue
                elif match '^OK|' "$RESPONSE"; then
                    WORD=$(echo "$RESPONSE" | parse_quiet '.' 'OK|\(.*\)')
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
            if [ -z "$CAPTCHA_TRADER" ]; then
                log_error "captcha.trader missing account data"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            local USERNAME="${CAPTCHA_TRADER%%:*}"
            local PASSWORD="${CAPTCHA_TRADER#*:}"

            log_notice "Using captcha.trader ($USERNAME)"

            RESPONSE=$(curl -F "match=" \
                -F "api_key=1645b45413c7e23a470475f33692cb63" \
                -F "password=$PASSWORD" \
                -F "username=$USERNAME" \
                -F "value=@$FILENAME;filename=file" \
                'http://api.captchatrader.com/submit') || return

            if [ -z "$RESPONSE" ]; then
                log_error "captcha.trader empty answer"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            if match '503 Service Unavailable' "$RESPONSE"; then
                log_error "captcha.trader server unavailable"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            local WORD
            TID=$(echo "$RESPONSE" | parse_quiet '.' '\[\([^,]*\)')
            WORD=$(echo "$RESPONSE" | parse_quiet '.' ',"\([^"]*\)')

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
        ocr_digit)
            RESPONSE=$(ocr "$FILENAME" digit | sed -e 's/[^0-9]//g') || {
                log_error "error running OCR";
                rm -f "$FILENAME";
                return $ERR_CAPTCHA;
            }
            echo "$RESPONSE"
            echo $TID
            ;;
        ocr_upper)
            RESPONSE=$(ocr "$FILENAME" upper | sed -e 's/[^a-zA-Z]//g') || {
                log_error "error running OCR";
                rm -f "$FILENAME";
                return $ERR_CAPTCHA;
            }
            echo "$RESPONSE"
            echo $TID
            ;;
        prompt)
            log_notice $TEXT1
            read -p "$TEXT2" RESPONSE
            [ -n "$PRGPID" ] && disown $(kill -9 $PRGPID) 2>&1 1>/dev/null
            echo "$RESPONSE"
            echo $TID
            ;;
        *)
            log_error "unknown solve method: $METHOD_SOLVE"
            rm -f "$FILENAME"
            return $ERR_FATAL
            ;;
    esac

    # if captcha URL provided, drop temporary image file
    if [ "$1" != "$FILENAME" ]; then
        rm -f "$FILENAME"
    fi
}

RECAPTCHA_SERVER="http://www.google.com/recaptcha/api/"
# reCAPTCHA decoding function
# Main engine: http://api.recaptcha.net/js/recaptcha.js
#
# $1: reCAPTCHA site public key
# stdout: On 3 lines: <word> \n <challenge> \n <transaction_id>
recaptcha_process() {
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

        WORDS=$(captcha_process "$FILENAME") || return
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

# Positive acknowledge of captcha answer
# $1: id (given by captcha_process or recpatcha_process)
captcha_ack() {
    [[ $1 -eq 0 ]] && return

    local M=${1:0:1}
    local TID=${1:1}
    local RESPONSE STR

    if [ c = "$M" ]; then
        if [ -n "$CAPTCHA_TRADER" ]; then
            local USERNAME="${CAPTCHA_TRADER%%:*}"
            local PASSWORD="${CAPTCHA_TRADER#*:}"

            log_debug "captcha.trader report ack ($USERNAME)"

            RESPONSE=$(curl -F "match=" \
                -F "is_correct=1"       \
                -F "ticket=$TID"        \
                -F "password=$PASSWORD" \
                -F "username=$USERNAME" \
                'http://api.captchatrader.com/respond') || return

            STR=$(echo "$RESPONSE" | parse_quiet '.' ',"\([^"]*\)')
            [ -n "$STR" ] && log_error "captcha.trader error: $STR"
        else
            log_error "$FUNCNAME failed: captcha.trader missing account data"
        fi
    else
        log_error "$FUNCNAME failed: unknown transaction ID: $1"
    fi
}

# Negative acknowledge of captcha answer
# $1: id (given by captcha_process or recpatcha_process)
captcha_nack() {
    [[ $1 -eq 0 ]] && return

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
            local USERNAME="${CAPTCHA_TRADER%%:*}"
            local PASSWORD="${CAPTCHA_TRADER#*:}"

            log_debug "captcha.trader report nack ($USERNAME)"

            RESPONSE=$(curl -F "match=" \
                -F "is_correct=0"       \
                -F "ticket=$TID"        \
                -F "password=$PASSWORD" \
                -F "username=$USERNAME" \
                'http://api.captchatrader.com/respond') || return

            STR=$(echo "$RESPONSE" | parse_quiet '.' ',"\([^"]*\)')
            [ -n "$STR" ] && log_error "captcha.trader error: $STR"
        else
            log_error "$FUNCNAME failed: captcha.trader missing account data"
        fi

    else
        log_error "$FUNCNAME failed: unknown transaction ID: $1"
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

# Related to --timeout plowdown command line option
timeout_init() {
    PS_TIMEOUT=$1
}

# Show help info for options
#
# $1: options
# $2: indent string
print_options() {
    local STRING
    while read OPTION; do
        test "$OPTION" || continue
        IFS="," read VAR SHORT LONG VALUE HELP <<< "$OPTION"
        if [ -n "$SHORT" ]; then
            if test "$VALUE"; then
                STRING="${2}-${SHORT%:} $VALUE"
                test -n "$LONG" && STRING="$STRING, --${LONG%:}=$VALUE"
            else
                STRING="${2}-${SHORT%:}"
                test -n "$LONG" && STRING="$STRING, --${LONG%:}"
            fi
        # long option only
        else
            if test "$VALUE"; then
                STRING="${2}--${LONG%:}=$VALUE"
            else
                STRING="${2}--${LONG%:}"
            fi
        fi
        echo "$STRING: $HELP"
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
            print_options "$OPTIONS" '  '
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
    test ! -f "$CONFIG" && CONFIG="/etc/plowshare.conf"
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
                VALUE="${VALUE%?}"
                VALUE="${VALUE:1}"
            fi

            # Look for 'long_name' in options list
            OPTION=$(echo "$OPTIONS" | grep ",${NAME}:\?," | sed '1q') || true
            if [ -n "$OPTION" ]; then
                local VAR="${OPTION%%,*}"
                eval "$VAR=$(quote "$VALUE")"
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
    test ! -f "$CONFIG" && CONFIG="/etc/plowshare.conf"
    test -f "$CONFIG" || return 0

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
            SHORT=$(sed -e 's/:$//' <<< "$SHORT")
            LONG=$(sed -e 's/:$//' <<< "$LONG")

            # Look for 'module/option_name' (short or long) in section list
            LINE=$(echo "$SECTION" | grep "^$M/\($SHORT\|$LONG\)[[:space:]]*=" | sed -n '$p') || true
            if [ -n "$LINE" ]; then
                VALUE=$(echo "${LINE#*=}" | strip)

                # Look for optional double quote (protect leading/trailing spaces)
                if [ '"' = "${VALUE:0:1}" -a '"' = "${VALUE:(-1):1}" ]; then
                    VALUE="${VALUE%?}"
                    VALUE="${VALUE:1}"
                fi

                eval "$VAR=$(quote "$VALUE")"
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
        if check_exec 'curl'; then
            log_report "[curl] $($(type -P curl) --version | sed 1q)"
        else
            log_report '[curl] not found!'
        fi
        check_exec 'gsed' && G=g
        log_report "[sed ] $($(type -P ${G}sed) --version | sed -ne '/version/p')"
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
            [[ "$2" ]] && unset "$2" && eval $2=\"\$1\"
            [[ "$3" ]] && unset "$3" && eval $3=\"none\"
            ;;
        prompt)
            [[ "$2" ]] && unset "$2" && eval $2=\"\$1\"
            [[ "$3" ]] && unset "$3" && eval $3=\"\"
            ;;
        online)
            local SITE
            if [ -n "$CAPTCHA_ANTIGATE" ]; then
                SITE=antigate
            elif [ -n "$CAPTCHA_TRADER" ]; then
                SITE=captchatrader
            else
                log_error "Error: no captcha solver account provided"
                return $ERR_FATAL
            fi
            [[ "$2" ]] && unset "$2" && eval $2=\"\$SITE\"
            [[ "$3" ]] && unset "$3" && eval $3=\"none\"
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
    sed '/^[ 	]*$/d'
}

# Look for a configuration module variable
# Example: MODULE_ZSHARE_DOWNLOAD_OPTIONS (result can be multiline)
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

# OCR of an image (using Tesseract engine)
#
# $1: image file (any format)
# $2: optional varfile
# stdout: result OCRed text
ocr() {
    local OPT_CONFIGFILE="$LIBDIR/tesseract/plowshare_nobatch"
    local OPT_VARFILE="$LIBDIR/tesseract/$2"
    test -f "$OPT_VARFILE" || OPT_VARFILE=''

    # We must create temporary files here, because
    # Tesseract does not deal with stdin/pipe argument
    TIFF=$(create_tempfile '.tif') || return
    TEXT=$(create_tempfile '.txt') || return

    convert -quiet "$1" tif:"$TIFF"
    LOG=$(tesseract "$TIFF" ${TEXT/%.txt} $OPT_CONFIGFILE $OPT_VARFILE 2>&1) || {
        rm -f "$TIFF" "$TEXT";
        log_error "$LOG";
        return $ERR_SYSTEM;
    }

    cat "$TEXT"
    rm -f "$TIFF" "$TEXT"
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

# Verify balance (antigate)
# $1: antigate.com captcha key
# $?: 0 for success (enough credits)
captcha_antigate_ready() {
    local KEY=$1
    local AMOUNT

    if [ -z "$KEY" ]; then
        log_error "antigate: missing captcha key"
        return $ERR_FATAL
    fi

    AMOUNT=$(curl --get --data "key=${CAPTCHA_ANTIGATE}&action=getbalance"  \
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
