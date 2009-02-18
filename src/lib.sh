#!/bin/bash
#
# Library for plowshare.
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
    S=$(sed -n "/$1/ s/^.*$2.*$/\1/p" | head -n1) && 
        test "$S" && echo "$S" || return 1 
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

# Straighforward options/arguments processing using getopt style
#
# Example:
#
# set -- "-a user:password -q arg1 arg2"
# $ eval "$(process_options "a:,auth:,AUTH q,quiet,QUIET" "$@")"
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

# OCR of an image. Write OCRed text to standard input
#
# Standard input: image 
ocr() {
    check_exec "convert" ||
        { debug "convert not found (install imagemagick)"; return; }
    check_exec "tesseract" ||
        { debug "tesseract not found (install tesseract-ocr)"; return; }
    TEMP=$(tempfile -s ".tif")
    TEMP2=$(tempfile -s ".txt")
    convert - tif:- > $TEMP
    tesseract $TEMP ${TEMP2/%.txt}
    TEXT=$(cat $TEMP2 | xargs)
    rm -f $TEMP $TEMP2
    echo "$TEXT"
}

# Get module name from URL
#
# $1: URL 
get_module() {
    URL=$1
    MODULES=$2
    for MODULE in $MODULES; do
        VAR=MODULE_$(echo $MODULE | tr '[a-z]' '[A-Z]')_REGEXP_URL
        match "${!VAR}" "$URL" && { echo $MODULE; return; } || true    
    done     
} 

# Show usage info for modules
debug_options_for_modules() {
    MODULES=$1
    NAME=$2
    for MODULE in $MODULES; do
        VAR="MODULE_$(echo $MODULE | tr '[a-z]' '[A-Z]')_${NAME}_OPTIONS"
        OPTIONS=${!VAR}
        if test "$OPTIONS"; then
            debug
            debug "Options for module <$MODULE>:"
            debug
            for OPTION in $OPTIONS; do
                IFS="," read SHORT LONG VAR VALUE <<< "$OPTION"
                echo "$HELP" | while read LINE; do
                    debug "  -${SHORT%:} $VALUE, --${LONG%:}=$VALUE"
                done
            done
        fi        
    done
}
