#!/bin/bash
#
# Common set of functions used by modules
# Copyright (c) 2010 - 2011 Plowshare team
#
# Global variables used:
#   - VERBOSE          Verbose log level (0=none, 1, 2, 3, 4)
#   - INTERFACE        Network interface (used by curl)
#   - PS_TIMEOUT       Timeout (in seconds) for one URL download
#   - PS_RETRY_LIMIT   Number of tries for loops (mainly for captchas)
#   - LIBDIR           Absolute path to plowshare's libdir
#   - RECAPTCHA_SERVER Server URL
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

# Logs are sent to standard error.
# Policies:
# - error: modules errors (when return 1), lastest plowdown curl call
# - notice: core messages (ocr, wait, timeout, retries), lastest plowdown curl call
# - debug: modules messages, curl (intermediate) calls
# - report: debug plus curl content (html pages, cookies)

log_report() {
    test $(verbose_level) -ge 4 && stderr "rep: $@"
    return 0
}

# log_report for a file
logcat_report() {
    local STRING=$(cat $1 | \
        sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' -e 's/^/rep:/')

    test $(verbose_level) -ge 4 && stderr "$STRING"
    return 0
}

log_debug() {
    test $(verbose_level) -ge 3 && stderr "dbg: $@"
    return 0
}

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
    local -a OPTIONS=(--insecure -A 'Mozilla Firefox 3.0')
    local -a POST_OPTIONS=()
    local DRETVAL=0

    # no verbose unless debug level; don't show progress meter for report level too
    test $(verbose_level) -ne 3 && OPTIONS=("${OPTIONS[@]}" "--silent")

    test -n "$INTERFACE" && OPTIONS=("${OPTIONS[@]}" "--interface" "$INTERFACE")
    test -n "$GLOBAL_COOKIES" &&
      POST_OPTIONS=("${POST_OPTIONS[@]}" "-b" "$GLOBAL_COOKIES" -c "$GLOBAL_COOKIES")
    set -- $(type -P curl) "${OPTIONS[@]}" "$@" "${POST_OPTIONS[@]}"

    if test $(verbose_level) -lt 4; then
        "$@" || DRETVAL=$?
    else
        local TEMPCURL=$(create_tempfile)
        log_report "$@"
        "$@" | tee "$TEMPCURL" || DRETVAL=$?
        FILESIZE=`stat -c %s $TEMPCURL 2>/dev/null`
        log_report "Received ${FILESIZE:-?} bytes"
        log_report "=== CURL BEGIN ==="
        logcat_report "$TEMPCURL"
        log_report "=== CURL END ==="
        rm -rf "$TEMPCURL"
    fi

    return $DRETVAL
}

curl_with_log() {
    with_log curl "$@"
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
strip() {
    echo "$1" | sed "s/^[[:space:]]*//; s/[[:space:]]*$//"
}

# Return uppercase string
uppercase() {
    tr '[a-z]' '[A-Z]'
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

# Get first line that matches a regular expression and extract string from it.
#
# stdin: text data
# $1: POSIX-regexp to filter (get only the first matching line).
# $2: POSIX-regexp to match (use parenthesis) on the matched line.
parse_all() {
    local STRING=$(sed -n "/$1/s/^.*$2.*$/\1/p") &&
        test "$STRING" && echo "$STRING" ||
        { log_error "parse failed: sed -n \"/$1/$2\""; return 1; }
}

# Like parse_all, but get only first match
parse() {
    parse_all "$@" | head -n1
}

# Like parse_all, but get only last match
parse_last() {
    parse_all "$@" | tail -n1
}

# Like parse, but hide output to stderr
parse_quiet() {
    parse "$@" 2>/dev/null
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

# Return value of html attribute
parse_all_attr() {
    parse_all "$1" "$2=[\"']\?\([^\"'>]*\)"
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

# Return base of URL
# Example: http://www.host.com/a/b/c/d => http://www.host.com
#
# $1: URL
basename_url()
{
    # Bash >=3.0 supports regular expressions
    # [[ "$1" =~ (http://[^/]*) ]] && echo "${BASH_REMATCH[1]}" || echo "$1"
    echo $(expr match "$1" '\(http://[^/]*\)' || echo "$1")
}

# Return basename of file path
# Example: /usr/bin/foo.bar => foo.bar
#
# $1: filename
basename_file()
{
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
        perl -n -mHTML::Entities \
             -e 'BEGIN { eval{binmode(STDOUT,q[:utf8]);}; }; print HTML::Entities::decode_entities($_);'
    else
        log_notice "recode binary not found"
    fi
}

# Encode a text to include into an url.
# - check for "reserved characters" : $&+,/:;=?@
# - check for "unsafe characters": '<>#%{}|\^~[]`
# - check for space character
#
# stdin: data (example: relative URL)
# stdout: data (nearly complains RFC2396)
uri_encode_strict() {
    cat | sed -e 's/\$/%24/g' -e 's|/|%2F|g' -e 's/\%/%25/g' \
        -e 's/\x26/%26/g' -e 's/\x2B/%2B/g' -e 's/\x2C/%2C/g' \
        -e 's/\x3A/%3A/g' -e 's/\x3B/%3B/g' -e 's/\x3D/%3D/g' \
        -e 's/\x3F/%3F/g' -e 's/\x40/%40/g' -e 's/\x20/%20/g' \
        -e 's/\x22/%22/g' -e 's/\x3C/%3C/g' -e 's/\x3E/%3E/g' \
        -e 's/\x23/%23/g' -e 's/\x7B/%7B/g' -e 's/\x7D/%7D/g' \
        -e 's/\x7C/%7C/g' -e 's/\^/%5E/g' -e 's/\x7E/%7E/g' \
        -e 's/\x60/%60/g' -e 's/\\/%5C/g' -e 's/\[/%5B/g' -e 's/\]/%5D/g'
}

# Encode a complete url.
# - check for space character
# - do not check for "reserved characters" (use "uri_encode_strict" for that)
#
# Bad encoded URL request can lead to HTTP error 400.
# curl doesn't do any checks, whereas wget convert provided url.
#
# stdin: data (example: absolute URL)
# stdout: data (nearly complains RFC2396)
uri_encode() {
    cat | sed -e "s/\x20/%20/g"
}

# Decode a complete url.
# - check for space character
# - do not check for "reserved characters"
#
# stdin: data (example: absolute URL)
# stdout: data (nearly complains RFC2396)
uri_decode() {
    cat | sed -e "s/%20/\x20/g"
}

# Create a tempfile and return path
#
# $1: Suffix
create_tempfile() {
    SUFFIX=$1
    FILE="${TMPDIR:-/tmp}/$(basename_file $0).$$.$RANDOM$SUFFIX"
    : > "$FILE"
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
    test -z "$PASSWORD" && return 1 || return 0
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
    AUTH=$1
    COOKIE=$2
    POSTDATA=$3
    LOGINURL=$4
    CURL_ARGS=$5

    if test "$GLOBAL_COOKIES"; then
        REGEXP=$(echo "$LOGINURL" | grep -o "://[^/]*" | grep -o "[^.]*\.[^.]*$")
        if grep -q "^\.\?$REGEXP" "$GLOBAL_COOKIES" 2>/dev/null; then
            log_debug "cookies for site ($REGEXP) found in cookies file, login skipped"
            return
        fi
        log_debug "cookies not found for site ($REGEXP), continue login process"
    fi

    USER="${AUTH%%:*}"
    PASSWORD="${AUTH#*:}"

    if [ -z "$PASSWORD" -o "$AUTH" == "$PASSWORD" ]; then
        PASSWORD=$(prompt_for_password) || true
    fi

    log_notice "Starting login process: $USER/$(sed 's/./*/g' <<< "$PASSWORD")"

    DATA=$(eval echo $(echo "$POSTDATA" | sed "s/&/\\\\&/g"))

    # Yes, no quote around $CURL_ARGS
    RESULT=$(curl --cookie-jar "$COOKIE" --data "$DATA" $CURL_ARGS "$LOGINURL")

    # For now "-z" test is kept.
    # There is no known case of a null $RESULT on successful login.
    if [ -z "$RESULT" -o ! -s "${GLOBAL_COOKIES:-$COOKIE}" ]; then
        log_error "login request failed"
        return 1
    fi

    log_report "=== COOKIE BEGIN ==="
    logcat_report "$COOKIE"
    log_report "=== COOKIE END ==="

    echo "$RESULT"
    return 0
}

# Execute javascript code
#
# stdin: js script
# stdout: script results
# $?: boolean
javascript() {
    JS_PRG=$(detect_javascript)

    local TEMPSCRIPT=$(create_tempfile)
    cat > $TEMPSCRIPT

    log_report "interpreter:$JS_PRG"
    log_report "=== JAVASCRIPT BEGIN ==="
    logcat_report "$TEMPSCRIPT"
    log_report "=== JAVASCRIPT END ==="

    $JS_PRG "$TEMPSCRIPT"
    rm -rf "$TEMPSCRIPT"
    return 0
}

# Dectect if a JavaScript interpreter is installed
#
# stdout: path of executable
# $?: boolean (0 means found)
detect_javascript() {
    if ! check_exec 'js'; then
        log_notice "Javascript interpreter not found"
        return 1
    fi
    type -P 'js'
}

# Dectect if a Perl interpreter is installed
#
# stdout: path of executable
# $?: boolean (0 means found)
detect_perl() {
    if ! check_exec 'perl'; then
        log_notice "Perl interpreter not found"
        return 1
    fi
    type -P 'perl'
}

# Wait some time
#
# $1: Sleep duration
# $2: Unit (seconds | minutes)
wait() {
    local VALUE=$1
    local UNIT=$2

    if [ "$UNIT" = "minutes" ]; then
        UNIT_SECS=60
        UNIT_STR=minutes
    else
        UNIT_SECS=1
        UNIT_STR=seconds
    fi
    local TOTAL_SECS=$((VALUE * UNIT_SECS))

    timeout_update $TOTAL_SECS || return 1

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
    test "$PS_RETRY_LIMIT" -ge 0
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

# Display image (in ascii) and forward it (like tee command)
#
# stdin: image (binary). Can be any format.
# stdout: same image
show_image_and_tee() {
    test $(verbose_level) -lt 3 && { cat; return; }
    local TEMPIMG=$(create_tempfile)
    cat > $TEMPIMG
    if check_exec aview; then
        # libaa
        local IMG_PNM=$(create_tempfile)
        convert $TEMPIMG -negate -depth 8 pnm:$IMG_PNM
        aview -width 60 -height 28 -kbddriver stdin -driver stdout "$IMG_PNM" 2>/dev/null <<< "q" | \
            sed  -e '1d;/\x0C/,/\x0C/d' | \
            grep -v "^[[:space:]]*$" >&2
        rm -f "$IMG_PNM"
    elif check_exec img2txt; then
        # libcaca
        img2txt -W 60 -H 14 $TEMPIMG >&2
    else
        log_notice "Install aview or img2txt (libcaca) to display captcha image"
    fi
    cat $TEMPIMG
    rm -f $TEMPIMG
}

##
## reCAPTCHA functions (can be called from modules)
## Main engine: http://api.recaptcha.net/js/recaptcha.js
##
RECAPTCHA_SERVER="http://www.google.com/recaptcha/api/"

# $1: reCAPTCHA site public key
# stdout: image path
recaptcha_load_image() {
    local URL="${RECAPTCHA_SERVER}challenge?k=${1}&ajax=1"
    log_debug "reCaptcha URL: $URL"

    local VARS=$(curl -L "$URL")

    if [ -n "$VARS" ]; then
        local server=$(echo "$VARS" | parse_quiet 'server' "server[[:space:]]\?:[[:space:]]\?'\([^']*\)'")
        local challenge=$(echo "$VARS" | parse_quiet 'challenge' "challenge[[:space:]]\?:[[:space:]]\?'\([^']*\)'")

        log_debug "reCaptcha server: $server"
        log_debug "reCaptcha challenge: $challenge"

        # Image dimension: 300x57
        FILENAME="${TMPDIR:-/tmp}/recaptcha.${challenge}.jpg"
        curl "${server}image?c=${challenge}" -o "$FILENAME"

        log_debug "reCaptcha image: $FILENAME"
        echo "$FILENAME"
    fi
}

# $1: reCAPTCHA image filename
# stdout: challenge (string)
recaptcha_get_challenge_from_image() {
    basename_file "$1" | cut -d. -f2
}

# $1: reCAPTCHA site public key
# $2: reCAPTCHA image filename
# stdout: new image path
recaptcha_reload_image() {
    FILENAME="$2"

    if [ -n "$FILENAME" ]; then
        local challenge=$(recaptcha_get_challenge_from_image "$FILENAME")
        local server="$RECAPTCHA_SERVER"

        STATUS=$(curl "${server}reload?k=$1&c=${challenge}&reason=r&type=image&lang=en")
        challenge=$(echo "$STATUS" | parse_quiet 'finish_reload' "('\([^']*\)")

        FILENAME="${TMPDIR:-/tmp}/recaptcha.${challenge}.jpg"
        curl "${server}image?c=${challenge}" -o "$FILENAME"

        log_debug "reCaptcha new image: $FILENAME"
        echo "$FILENAME"
    fi
}

# $1: reCAPTCHA image filename
# stdout: response word (string)
recaptcha_display_and_prompt() {
    FILENAME="$1"

    display $FILENAME &
    PID=$!

    log_notice "Leave this field blank and hit enter to get another captcha image"

    read -p "Enter captcha response (longuest word): " RESPONSE
    disown $(kill -9 $PID) 2>&1 1>/dev/null
    echo "$RESPONSE" | sed 's/ /+/g'
}

## ----------------------------------------------------------------------------

##
## Miscellaneous functions that can be called from core:
## download.sh, upload.sh, delete.sh, list.sh
##

# Force debug verbose level (unless -v0/-q specified)
with_log() {
    local TEMP_VERBOSE=3
    test $(verbose_level) -eq 0 && TEMP_VERBOSE=0 || true
    VERBOSE=$TEMP_VERBOSE "$@"
}

# Remove all temporal files created by the script
# (with create_tempfile)
remove_tempfiles() {
    rm -rf "${TMPDIR:-/tmp}/$(basename_file $0).$$.*"
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
# $1: url
# $2: module name list (string)
get_module() {
    URL=$1
    MODULES=$2
    for MODULE in $MODULES; do
        VAR=MODULE_$(echo $MODULE | uppercase)_REGEXP_URL
        if match "${!VAR}" "$URL"; then
            echo $MODULE
            break;
        fi
    done
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
    echo "$@" >&2;
}

quote() {
    for ARG in "$@"; do
        echo -n "$(declare -p ARG | sed "s/^declare -- ARG=//") "
    done | sed "s/ $//"
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
        return 1
    fi
    (( PS_TIMEOUT -= WAIT ))
}
