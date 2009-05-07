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

# Global variables:
#
# QUIET: If set, debug output is supressed
#

# Echo text to standard error.
#
debug() {
    if [ -z "$QUIET" ]; then 
        echo "$@" >&2
    fi
}

error() { 
    echo "Error: $@" >&2
}

# Wrapper for curl: debug and infinte loop control
#
curl() {
    OPTIONS=(--insecure)
    test "$QUIET" && OPTIONS=(${OPTIONS[@]} "-s")
    while true; do
        $(type -P curl) "${OPTIONS[@]}" "$@" && DRETVAL=0 || DRETVAL=$?
        if [ $DRETVAL -eq 6 -o $DRETVAL -eq 7 ]; then
            debug "curl failed with retcode $DRETVAL, trying again"
            continue
        else
            return $DRETVAL
        fi
    done    
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
    # Tesseract somewhat "peculiar" arguments requirement makes impossible 
    # to use pipes or process substitution. Create temporal files 
    # instead (*sigh*).
    TIFF=$(create_tempfile ".tif")
    TEXT=$(create_tempfile ".txt")
    convert - tif:- > $TIFF
    tesseract $TIFF ${TEXT/%.txt} || 
        { rm -f $TIFF $TEXT; return 1; }
    cat $TEXT
    rm -f $TIFF $TEXT
}

# Decode the 4-char (rotated) megaupload captcha
#
megaupload_ocr() {
    python $EXTRASDIR/megaupload_captcha.py "$@"
}

# Show help info for options
#
# $1: options${STRING:2}
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
        debug "$STRING: $HELP"
    done <<< "$OPTIONS"
}

get_modules_options() {
    MODULES=$1
    NAME=$2
    for MODULE in $MODULES; do
        get_options_for_module "$MODULE" "$NAME" | while read OPTION; do
            if test "$OPTION"; then echo "!$OPTION"; fi
        done
    done
}

# Return uppercase string
uppercase() {
    tr '[a-z]' '[A-Z]'
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
            debug; debug "Options for module <$MODULE>:"; debug
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
#
process_options() {
    quote() { 
        for ARG in "$@"; do 
            echo -n "$(declare -p ARG | sed "s/^declare -- ARG=//") " 
        done | sed "s/ $//"
    }
    NAME=$1
    OPTIONS=$2   
    shift 2
    # Strip spaces in options
    OPTIONS=$(grep -v "^[[:space:]]*$" <<< "$OPTIONS" | \
        sed "s/^[[:space:]]*//; s/[[:space:]]$//")
    while read VAR; do
        unset $VAR
    done < <(get_field 1 "$OPTIONS" | sed "s/^!//")
    ARGUMENTS="$(getopt -o "$(get_field 2 "$OPTIONS")" \
        --long "$(get_field 3 "$OPTIONS")" -n "$NAME" -- "$@")"
    eval set -- "$ARGUMENTS"
    UNUSED_OPTIONS=()
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

# Output image in ascii chars (uses aview)
#
ascii_image() {
    convert - -negate pnm:- | \
        aview "$@" -kbddriver stdin -driver stdout <(cat) 2>/dev/null <<< "q" | \
        awk 'BEGIN { part = 0; }
            /\014/ { part++; next; }
            // { if (part == 2) print $0; }' | \
        grep -v "^[[:space:]]*$"
}
