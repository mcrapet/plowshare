#!/bin/bash
#
# Common set of functions used by modules
# Copyright (c) 2010-2011 Plowshare team
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
ERR_NETWORK=3                    # Specific network error (socket reset, curl, etc)
ERR_LOGIN_FAILED=4               # Correct login/password argument is required
ERR_MAX_WAIT_REACHED=5           # Refer to plowdown wait timeout (see -t/--timeout command line option)
ERR_MAX_TRIES_REACHED=6          # Refer to plowdown max tries reached (see --max-retries command line option)
ERR_CAPTCHA=7                    # Captcha solving failure
ERR_SYSTEM=8                     # System failure (missing executable, local filesystem, wrong behavior, etc)
ERR_LINK_TEMP_UNAVAILABLE=10     # Link alive but temporarily unavailable
                                 # (also refer to plowdown --no-arbitrary-wait command line option)
ERR_LINK_PASSWORD_REQUIRED=11    # Link alive but requires a password
ERR_LINK_NEED_PERMISSIONS=12     # Link alive but requires some authentication (premium link)
                                 # or operation not allowed for anonymous user
ERR_LINK_DEAD=13                 #
ERR_FATAL_MULTIPLE=100           # 100 + (n) with n = first error code (when multiple arguments)

# Global variables used (defined in other .sh)
#   - VERBOSE          Verbose log level (0=none, 1, 2, 3, 4)
#   - INTERFACE        Network interface (used by curl)
#   - LIMIT_RATE       Network speed (used by curl)
#   - GLOBAL_COOKIES   User provided cookie
#   - LIBDIR           Absolute path to plowshare's libdir
#   - CAPTCHA_TRADER   CaptchaTrader account
#
# Global variables defined here:
#   - PS_TIMEOUT       Timeout (in seconds) for one URL download
#   - PS_RETRY_LIMIT   Number of tries for loops (mainly for captchas)
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
        local STRING=$(sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                           -e 's/^/rep:/' "$1")
        test $(verbose_level) -ge 4 && stderr "$STRING"
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
curl() {
    local -a OPTIONS=(--insecure --speed-time 600 --connect-timeout 300)

    # Check if caller has specified a User-Agent, if so, don't put one
    local exist=0
    for e; do
        if [ "$e" = '-A' -o "$e" = '--user-agent' ]; then
            exist=1
            break
        fi
    done
    if [ "$exist" -eq 0 ]; then
        OPTIONS[5]='--user-agent'
        OPTIONS[6]='Mozilla/5.0 (X11; Linux x86_64; rv:6.0) Gecko/20100101 Firefox/6.0'
    fi

    local DRETVAL=0

    # no verbose unless debug level; don't show progress meter for report level too
    test $(verbose_level) -ne 3 && OPTIONS=("${OPTIONS[@]}" "--silent")

    test -n "$INTERFACE" && OPTIONS=("${OPTIONS[@]}" "--interface" "$INTERFACE")
    test -n "$LIMIT_RATE" && OPTIONS=("${OPTIONS[@]}" "--limit-rate" "$LIMIT_RATE")

    if test -z "$GLOBAL_COOKIES"; then
        set -- $(type -P curl) "${OPTIONS[@]}" "$@"
    else
        set -- $(type -P curl) "-b $GLOBAL_COOKIES" "${OPTIONS[@]}" "$@"
    fi

    if test $(verbose_level) -lt 4; then
        "$@" || DRETVAL=$?
    else
        local TEMPCURL=$(create_tempfile)
        log_report "$@"
        "$@" --show-error 2>&1 | tee "$TEMPCURL" || DRETVAL=$?
        FILESIZE=$(get_filesize "$TEMPCURL")
        log_report "Received $FILESIZE bytes"
        log_report "=== CURL BEGIN ==="
        logcat_report "$TEMPCURL"
        log_report "=== CURL END ==="
        rm -rf "$TEMPCURL"
    fi

    case "$DRETVAL" in
        0)
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
    S="$(cat)"
    # We must escape '\' character
    FROM="${1//\\/\\\\}"
    echo "${S//$FROM/$2}"
}

# Delete leading and trailing spaces, tabs, \r, ...
# stdin: input string (can be multiline)
# stdout: result string
strip() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Return uppercase string : tr '[:lower:]' '[:upper:]'
# Note: Busybox "tr" command may not have classes support (CONFIG_FEATURE_TR_CLASSES)
uppercase() {
    tr '[a-z]' '[A-Z]'
}

# Return lowercase string : tr '[:upper:]' '[:lower:]'
lowercase() {
    tr '[A-Z]' '[a-z]'
}

# Grep first line of a text
# stdin: input string (multiline)
first_line() {
    # equivalent to `sed -e 1q`
    head -n1
}

# Grep last line of a text
# stdin: input string (multiline)
last_line() {
    # equivalent to `sed -ne '$p'`
    tail -n1
}

# Grep nth line of a text
# stdin: input string (multiline)
# $1: line number (start at index 1)
nth_line() {
   # equivalent to `sed -e "${1}q;d"`
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
    grep -q "$1" <<< "$2"
}

# Check if a string ($2) matches a regexp ($1)
# This is not case sensitive.
#
# $? is zero on success
matchi() {
    grep -iq "$1" <<< "$2"
}

# Check if URL is suitable for remote upload
#
# $1: string (URL or anything)
match_remote_url() {
    matchi "^[[:space:]]*https\?://" "$1"
}

# Get lines that match filter+match regular expressions and extract string from it.
#
# stdin: text data
# $1: POSIX-regexp to filter (get only the first matching line).
# $2: POSIX-regexp to match (use parenthesis) on the matched line.
parse_all() {
    local STRING=$(sed -n "/$1/s/^.*$2.*$/\1/p")
    test "$STRING" && echo "$STRING" ||
        { log_error "parse failed: sed -n \"/$1/$2\""; return $ERR_FATAL; }
}

# Like parse_all, but get only first match
parse() {
    parse_all "$@" | head -n1
}

# Like parse_all, but get only last match
parse_last() {
    parse_all "$@" | tail -n1
}

# Like parse, but hide possible error
parse_quiet() {
    parse "$@" 2>/dev/null
}

# Get lines that first filter regex, then apply match regex on the line after
#
# stdin: text data
# $1: POSIX-regexp to filter (get only the first matching line).
# $2: POSIX-regexp to match (use parenthesis) on the matched line.
parse_line_after_all() {
    local STRING=$(sed -n "/$1/{n;s/^.*$2.*$/\1/p}")
    test "$STRING" && echo "$STRING" ||
        { log_error "parse failed: sed -n \"/$1/$2\""; return $ERR_FATAL; }
}

# Like parse_line_after_all, but get only first match
parse_line_after() {
    parse_line_after_all "$@" | head -n1
}

# Grep first "Location" (of http header)
#
# stdin: result of curl request (with -i/--include, -D/--dump-header or
#        or -I/--head flag)
grep_http_header_location() {
    sed -n 's/^[Ll]ocation:[[:space:]]\+\([^ ]*\)/\1/p' 2>/dev/null | tr -d "\r"
}

grep_http_header_content_location() {
    sed -n 's/^[Cc]ontent-[Ll]ocation:[[:space:]]\+\([^ ]*\)/\1/p' 2>/dev/null | tr -d "\r"
}

grep_http_header_content_type() {
    sed -n 's/^[Cc]ontent-[Tt]ype:[[:space:]]\+\([^ ]*\)/\1/p' 2>/dev/null | tr -d "\r"
}

# Grep first "Content-Disposition" (of http header)
#
# stdin: same as grep_http_header_location() below
# stdout: attachement filename
grep_http_header_content_disposition() {
    parse "[Cc]ontent-[Dd]isposition:" 'filename="\(.*\)"' 2>/dev/null
}

# Extract a specific form from a HTML content.
# We assume here that start marker <form> and end marker </form> are one separate lines.
# HTML comments are just ignored. But it's enough for our needs.
#
# $1: (X)HTML data
# $2: (optional) Nth <form> (default is 1)
# stdout: result
grep_form_by_order() {
    local DATA="$1"
    local N=${2:-"1"}

    while [ "$N" -gt "1" ]; do
        (( N-- ))
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

# Split into several lines html markers.
# Insert a new line after ending marker.
#
# stdin: (X)HTML data
# stdout: result
break_html_lines() {
    sed 's/\(<\/[^>]*>\)/\1\n/g'
}

# Split into several lines html markers.
# Insert a new line after each (beginning or ending) marker.
#
# stdin: (X)HTML data
# stdout: result
break_html_lines_alt() {
    sed 's/\(<[^>]*>\)/\1\n/g'
}

# Return value of html attribute
parse_attr() {
    parse "$1" "$2=[\"']\?\([^\"'>]*\)"
}

# Like parse_attr, but hide possible error
parse_attr_quiet() {
    parse_attr "$@" 2>/dev/null
}

# Return value of html attribute
parse_all_attr() {
    parse_all "$1" "$2=[\"']\?\([^\"'>]*\)"
}

# Like parse_all_attr, but hide possible error
parse_all_attr_quiet() {
    parse_all_attr "$@" 2>/dev/null
}

# Retreive "action" attribute (URL) from a <form> marker
#
# stdin: (X)HTML data (idealy, call grep_form_by_xxx before)
# stdout: result
parse_form_action() {
    parse '<[Ff][Oo][Rr][Mm]' 'action="\([^"]*\)"'
}

# Retreive "value" attribute from a named <input> marker
#
# $1: name attribute of <input> marker
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_name() {
    parse_quiet "<input\([[:space:]]*[^ ]*\)*name=[\"']\?$1[\"']\?" "value=[\"']\?\([^'\">]*\)"
}

# Retreive "value" attribute from a typed <input> marker
#
# $1: type attribute of <input> marker (for example: "submit")
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_type() {
    parse_quiet "<input\([[:space:]]*[^ ]*\)*type=[\"']\?$1[\"']\?" "value=[\"']\?\([^'\">]*\)"
}

# Retreive "id" attributes from typed <input> marker(s)
parse_all_form_input_by_type_with_id() {
    parse_all "<input\([[:space:]]*[^ ]*\)*type=[\"']\?$1[\"']\?" "id=[\"']\?\([^'\">]*\)" 2>/dev/null
}

# Get accessor for cookies
# Example: LANG=$(parse_cookie "lang" < "$COOKIES")
parse_cookie() {
    parse_quiet "\t$1\t[^\t]*\$" "\t$1\t\(.*\)"
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
             -e 'BEGIN { eval{binmode(STDOUT,q[:utf8]);}; }; print HTML::Entities::decode_entities($_);'
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
    sed -e 's/\%/%25/g'   -e 's/\x20/%20/g' \
        -e 's/\x21/%21/g' -e 's/\x2A/%2A/g' -e 's/\x27/%27/g' \
        -e 's/\x28/%28/g' -e 's/\x29/%29/g' -e 's/\x3B/%3B/g' \
        -e 's/\x3A/%3A/g' -e 's/\x40/%40/g' -e 's/\x26/%26/g' \
        -e 's/\x3D/%3D/g' -e 's/\x2B/%2B/g' -e 's/\$/%24/g'   \
        -e 's/\x2C/%2C/g' -e 's|/|%2F|g'    -e 's/\x3F/%3F/g' \
        -e 's/\x23/%23/g' -e 's/\[/%5B/g'   -e 's/\]/%5D/g'
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
    sed -e 's/\x20/%20/g' -e 's/\[/%5B/g' -e 's/\]/%5D/g'
}

# Decode a complete url.
# - check for space character and round/squares brackets
# - reserved characters: only coma is checked
#
# stdin: data (example: absolute URL)
# stdout: data (nearly complain RFC3986)
uri_decode() {
    sed -e 's/%20/\x20/g' -e 's/%5B/\[/g' -e 's/%5D/\]/g' \
        -e 's/%2C/,/g' -e 's/%28/(/g' -e 's/%29/)/g' -e 's/%2B/+/g'
}

# Retrieves size of file
#
# $1: filename
# stdout: file length (in bytes)
get_filesize() {
    local SIZE=`stat -c %s "$1" 2>/dev/null`
    if [ -z "$SIZE" ]; then
        log_error "stat binary not found"
        echo "-1"
    else
        echo "$SIZE"
    fi
}

# Create a tempfile and return path
#
# $1: Suffix
create_tempfile() {
    SUFFIX=$1
    FILE="${TMPDIR:-/tmp}/$(basename_file $0).$$.$RANDOM$SUFFIX"
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
    stty -echo
    read -p "Enter password: " PASSWORD
    stty echo

    echo "$PASSWORD"
    test -n "$PASSWORD" || return $ERR_LINK_PASSWORD_REQUIRED
}

# Login and return cookie.
# A non empty cookie file does not means that login is successful.
#
# $1: String 'username:password' (password can contain semicolons)
# $2: Cookie filename (see create_tempfile() modules)
# $3: Postdata string (ex: 'user=\$USER&password=\$PASSWORD')
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

    if test "$GLOBAL_COOKIES"; then
        REGEXP=$(echo "$LOGINURL" | basename_url | grep -o "[^.]*\.[^.]*$")
        if grep -q "^\.\?$REGEXP" "$GLOBAL_COOKIES" 2>/dev/null; then
            log_debug "cookies for site ($REGEXP) found in cookies file, login skipped"
            return
        fi
        log_debug "cookies not found for site ($REGEXP), continue login process"
    fi

    local USER PASSWORD DATA RESULT

    # Seem faster than
    # IFS=":" read USER PASSWORD <<< "$AUTH"
    USER=$(echo "${AUTH%%:*}" | uri_encode_strict)
    PASSWORD=$(echo "${AUTH#*:}" | uri_encode_strict)

    if [ -z "$PASSWORD" -o "$AUTH" == "$PASSWORD" ]; then
        PASSWORD=$(prompt_for_password) || true
    fi

    log_notice "Starting login process: $USER/$(sed 's/./*/g' <<< "$PASSWORD")"

    DATA=$(eval echo $(echo "$POSTDATA" | sed "s/&/\\\\&/g"))

    # Yes, no quote around $CURL_ARGS
    RESULT=$(curl --cookie-jar "$COOKIE" --data "$DATA" $CURL_ARGS "$LOGINURL") || return

    # For now "-z" test is kept.
    # There is no known case of a null $RESULT on successful login.
    if [ -z "$RESULT" -o ! -s "${GLOBAL_COOKIES:-$COOKIE}" ]; then
        log_error "login request failed"
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
    rm -rf "$TEMPSCRIPT"
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
          (( REMAINING-- ))
      done
      log_notice -e "\r$MSG done${CLEAR}"
    else
      log_notice "$MSG"
      sleep $TOTAL_SECS
    fi
}

# Related to --max-retries plowdown command line option
retry_limit_not_reached() {
    test -z "$PS_RETRY_LIMIT" && return
    log_notice "Tries left: $PS_RETRY_LIMIT"
    (( PS_RETRY_LIMIT-- ))
    test "$PS_RETRY_LIMIT" -ge 0 || return $ERR_MAX_TRIES_REACHED
}

# $1: local image filename (with full path). No specific image format expected.
# $2 (optional): solve method
# $3 (optional): view method (null string means autodetect)
# stdout: captcha answer + optional ID (on a second line)
#         nothing is printed in case of error
#
# Important note: input image ($1) is deleted in case of error
captcha_process() {
    local FILENAME="$1"
    local METHOD_SOLVE=$2
    local METHOD_VIEW=$3

    if [ ! -f "$FILENAME" ]; then
        log_error "image file not found"
        return $ERR_CAPTCHA
    fi

    if [ -z "$METHOD_SOLVE" ]; then
        METHOD_SOLVE=prompt
    elif [ "${METHOD_SOLVE:0:3}" = 'ocr' ]; then
        if ! check_exec 'tesseract'; then
            log_notice "tesseract was not found, fallback to manual entering"
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
            log_debug "no X server available, try ascii display"
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
            MAX_OUTPUT_WIDTH=`tput cols`
            MAX_OUTPUT_HEIGHT=`tput lines`
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
            log_debug "image: $FILENAME"
            ;;
        aview)
            local IMG_PNM=$(create_tempfile '.pnm')
            convert "$FILENAME" -negate -depth 8 pnm:$IMG_PNM
            aview -width $MAX_OUTPUT_WIDTH -height $MAX_OUTPUT_HEIGHT \
                -kbddriver stdin -driver stdout "$IMG_PNM" 2>/dev/null <<< "q" | \
                sed  -e '1d;/\x0C/,/\x0C/d' | grep -v "^[[:space:]]*$" 1>&2
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
    local TEXT1='Leave this field blank and hit enter to get another captcha image'
    local TEXT2='Enter captcha response (drop punctuation marks, case insensitive): '

    # How to solve captcha
    case "$METHOD_SOLVE" in
        none)
            ;;
        captchatrader)
            if [ -z "$CAPTCHA_TRADER" ]; then
                log_error "captcha.trader missing account data"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            local USERNAME="${CAPTCHA_TRADER%%:*}"
            local PASSWORD="${CAPTCHA_TRADER#*:}"

            log_notice "Using catpcha.trader ($USERNAME)"

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

            local RET WORD
            RET=$(echo "$RESPONSE" | parse_quiet '.' '\[\([^,]*\)')
            WORD=$(echo "$RESPONSE" | parse_quiet '.' ',"\([^"]*\)')

            if [ "$RET" -eq '-1' ]; then
                log_error "captcha.trader error: $WORD"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            # result on two lines
            echo "$WORD"
            echo $RET
            ;;
        ocr_digit)
            RESPONSE=$(ocr "$FILENAME" digit | sed -e 's/[^0-9]//g') || {
                log_error "error running OCR";
                rm -f "$FILENAME";
                return $ERR_CAPTCHA;
            }
            echo "$RESPONSE"
            ;;
        ocr_upper)
            RESPONSE=$(ocr "$FILENAME" upper | sed -e 's/[^a-zA-Z]//g') || {
                log_error "error running OCR";
                rm -f "$FILENAME";
                return $ERR_CAPTCHA;
            }
            echo "$RESPONSE"
            ;;
        prompt)
            log_notice $TEXT1
            read -p "$TEXT2" RESPONSE
            [ -n "$PRGPID" ] && disown $(kill -9 $PRGPID) 2>&1 1>/dev/null
            echo "$RESPONSE"
            ;;
        *)
            log_error "unknown solve method: $METHOD_SOLVE"
            rm -f "$FILENAME"
            return $ERR_CAPTCHA
            ;;
    esac
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

        if [ -z "$CAPTCHA_TRADER" ]; then
            WORDS=$(captcha_process "$FILENAME") || return
        else
            WORDS=$(captcha_process "$FILENAME" 'captchatrader' 'none') || return
        fi
        rm -f "$FILENAME"

        { read WORDS; read TID; } <<<"$WORDS"

        [ -n "$WORDS" ] && break

        # Reload image
        log_debug "empty, request another image"

        # Result: Recaptcha.finish_reload('...', 'image');
        VARS=$(curl "${SERVER}reload?k=${1}&c=${CHALLENGE}&reason=r&type=image&lang=en") || return
        CHALLENGE=$(echo "$VARS" | parse_quiet 'finish_reload' "('\([^']*\)") || return
    done

    WORDS=$(echo "$WORDS" | uri_encode)

    echo "$WORDS"
    echo "$CHALLENGE"
    echo "${TID:-0}"
}

# Positive acknowledge of reCaptcha answer
# $1: id (given by recaptcha_process)
recaptcha_ack() {
    if [[ "$1" -ne 0 ]]; then
        if [ -n "$CAPTCHA_TRADER" ]; then
            local RESPONSE STR

            local USERNAME="${CAPTCHA_TRADER%%:*}"
            local PASSWORD="${CAPTCHA_TRADER#*:}"

            log_debug "catpcha.trader report ack ($USERNAME)"

            RESPONSE=$(curl -F "match=" \
                -F "is_correct=1"       \
                -F "ticket=$1"          \
                -F "password=$PASSWORD" \
                -F "username=$USERNAME" \
                'http://api.captchatrader.com/respond') || return

            STR=$(echo "$RESPONSE" | parse_quiet '.' ',"\([^"]*\)')
            [ -n "$STR" ] && log_error "captcha.trader error: $STR"
        fi
    fi
}

# Negative acknowledge of reCaptcha answer
# $1: id (given by recaptcha_process)
recaptcha_nack() {
    if [[ "$1" -ne 0 ]]; then
        if [ -n "$CAPTCHA_TRADER" ]; then
            local RESPONSE STR

            local USERNAME="${CAPTCHA_TRADER%%:*}"
            local PASSWORD="${CAPTCHA_TRADER#*:}"

            log_debug "catpcha.trader report nack ($USERNAME)"

            RESPONSE=$(curl -F "match=" \
                -F "is_correct=0"       \
                -F "ticket=$1"          \
                -F "password=$PASSWORD" \
                -F "username=$USERNAME" \
                'http://api.captchatrader.com/respond') || return

            STR=$(echo "$RESPONSE" | parse_quiet '.' ',"\([^"]*\)')
            [ -n "$STR" ] && log_error "captcha.trader error: $STR"
        fi
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
    trap "remove_tempfiles" EXIT
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

# Related to --max-retries plowdown command line option
retry_limit_init() {
    PS_RETRY_LIMIT=$1
}

# Show help info for options
#
# $1: options
# $2: indent string
print_options() {
    local OPTIONS=$1
    while read OPTION; do
        test "$OPTION" || continue
        IFS="," read VAR SHORT LONG VALUE HELP <<< "$OPTION"
        STRING=$2
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
        local M=$(uppercase <<< "$MODULE")
        local VAR="MODULE_${M}_REGEXP_URL"
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
    local ARGUMENTS="$(getopt -o "$SHORT_OPTS" --long "$LONG_OPTS" -n "$NAME" -- "$@")"

    # To correctly process whitespace and quotes.
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

   sed -ne "/^[^#].*|[[:space:]]*$1[[:space:]]*|/p" $CONFIG | \
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
            if [ "${VALUE:0:1}" = '"' -a "${VALUE:(-1):1}" = '"' ]; then
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
        local M=$(echo "$2" | lowercase)

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
                if [ "${VALUE:0:1}" = '"' -a "${VALUE:(-1):1}" = '"' ]; then
                    VALUE="${VALUE%?}"
                    VALUE="${VALUE:1}"
                fi

                eval "$VAR=$(quote "$VALUE")"
                log_debug "$M: take --$LONG option from configuration file"
            fi
        done <<< "$OPTIONS"
    fi
}

# Get system information
log_report_info() {
    local G

    if test $(verbose_level) -ge 4; then
        log_report '=== SYSTEM INFO BEGIN ==='
        log_report "[mach] `uname -a`"
        log_report "[bash] `echo $BASH_VERSION`"
        if check_exec 'curl'; then
            log_report "[curl] `$(type -P curl) --version | sed 1q`"
        else
            log_report '[curl] not found!'
        fi
        check_exec 'gsed' && G=g
        log_report "[sed ] `$(type -P ${G}sed) --version | sed -ne '/version/p'`"
        log_report '=== SYSTEM INFO END ==='
    fi
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
    echo "$@" >&2;
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
    local MODULE=$(uppercase <<< "$1")
    local VAR="MODULE_${MODULE}_${2}_OPTIONS"
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

# called by wait
timeout_update() {
    local WAIT=$1
    test -z "$PS_TIMEOUT" && return
    log_notice "Time left to timeout: $PS_TIMEOUT secs"
    if [[ "$PS_TIMEOUT" -lt "$WAIT" ]]; then
        log_debug "timeout reached (asked $WAIT secs to wait, but remaining time is $PS_TIMEOUT)"
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
