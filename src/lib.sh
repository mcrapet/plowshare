#!/bin/bash
#
# Library for plowshare.
#
# License: GNU GPL v3.0: http://www.gnu.org/licenses/gpl-3.0-standalone.html
#

# Echo text to standard error.
#
debug() { 
    echo "$@" >&2
}

# Get first line that matches a regular expression and extract string from it.
#
# $1: POSIX-regexp to filter (get only the first matching line).
# $2: POSIX-regexp to match (use parentheses) on the matched line.
#
parse() { 
    STRING=$(sed -n "/$1/ s/^.*$2.*$/\1/p" | head -n1) && 
        test "$STRING" && echo "$STRING" || 
        { debug "parse failed: /$1/ $2"; return 1; } 
}

# Check if a string ($2) matches a regexp ($1)
#
match() { 
    grep -q "$1" <<< "$2"
}

# Check existance of executable in path
#
# $1: Executable to check 
check_exec() {
    type -P $1 > /dev/null
}

# Check if function is defined
#
check_function() {
    declare -F "$1" &>/dev/null
}

# Straighforward options and arguments processing using getopt style
#
# Example:
#
# set -- -a user:password -q arg1 arg2
# $ eval "$(process_options "a:,auth:,AUTH,USER:PASSWORD q,quiet,QUIET" "$@")"
# $ echo "$AUTH / $QUIET / $1 / $2"
# user:password / 1 / arg1 / arg2
#
process_options() {
    OPTIONS=$1
    shift
    get_field() { for ARG in $2; do echo $ARG | cut -d"," -f$1; done | xargs; }
    VARS=$(get_field 3 "$OPTIONS")
    ARGUMENTS="$(getopt -o "$(get_field 1 "$OPTIONS")" \
        --long "$(get_field 2 "$OPTIONS")" -n 'plowshare' -- "$@")"        
    eval set -- "$ARGUMENTS"
    unset $VARS
    while true; do
        for OPTION in $OPTIONS; do
            IFS="," read SHORT LONG VAR VALUE <<< "$OPTION"
            if [ "$1" = "-${SHORT%:}" -o "$1" = "--${LONG%:}" ]; then
                if [ "${SHORT:${#SHORT}-1:1}" = ":" -o \
                        "${LONG:${#LONG}-1:1}" = ":" ]; then
                    echo "$VAR='$2'"
                    shift 2
                else
                    echo "$VAR=1"
                    shift
                fi
                break
            elif [ "$1" = "--" ]; then
                shift
                break 2
            fi
        done
    done
    echo "set -- $(for ARG in "$@"; do echo "'$ARG'"; done | xargs -d"\n")"
}

# Login and return cookies
#
# $1: String 'username:password'
# $2: Postdata string (ex: 'user=\$USER&password=\$PASSWORD')
# $3: URL to post
post_login() {
    AUTH=$1
    POSTDATA=$2
    LOGINURL=$3
    
    if test "$AUTH"; then
        IFS=":" read USER PASSWORD <<< "$AUTH" 
        debug "starting login process: $USER/$(sed 's/./*/g' <<< "$PASSWORD")"
        DATA=$(eval echo $(echo "$POSTDATA" | sed "s/&/\\\\&/g"))
        COOKIES=$(curl -o /dev/null -c - -d "$DATA" "$LOGINURL")
        test "$COOKIES" || { debug "login error"; return 1; }
        echo "$COOKIES"
    fi
}

# Create a tempfile and return path
#
# $1: Suffix
#
create_tempfile() {
    SUFFIX=$1
    FILE="${TMPDIR:-/tmp}/$(basename $0).$$.$RANDOM$SUFFIX"
    : > "$FILE"
    echo "$FILE"
}

# OCR of an image. Write OCRed text to standard input
#
# Standard input: image 
ocr() {
    # Tesseract is somewhat "peculiar" and it's impossible to use pipes
    # or process substitution. So let's use temporal files instead (*sigh*).
    TIFF=$(create_tempfile ".tif")
    TEXT=$(create_tempfile ".txt")
    convert - tif:- > $TIFF
    tesseract $TIFF ${TEXT/%.txt}
    cat $TEXT
    rm -f $TIFF $TEXT
}

# Get module name from URL link
#
# $1: URL 
get_module() {
    URL=$1
    MODULES=$2
    for MODULE in $MODULES; do
        VAR=MODULE_$(echo $MODULE | tr '[a-z]' '[A-Z]')_REGEXP_URL
        match "${!VAR}" "$URL" && { echo $MODULE; return; } || true    
    done
    return 1     
}

# Show help info for options
#
# $1: options
# $2: indent string
debug_options() {
    OPTIONS=$1
    INDENTING=$2
    for OPTION in $OPTIONS; do
        IFS="," read SHORT LONG VAR VALUE <<< "$OPTION"
        echo "$HELP" | while read LINE; do
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
            debug "$STRING"
        done
    done
}
