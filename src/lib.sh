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

# Login and return cookies
#
# $1: URL to post
# $2: data to post
post_login() {
    USER=$1
    PASSWORD=$2   
    LOGINURL=$3
    DATA=$4
    if test "$USER" -a "$PASSWORD"; then
        debug "starting login process: $USER/$(sed 's/./*/g' <<< "$PASSWORD")"
        COOKIES=$(curl -o /dev/null -c - -d "$DATA" "$LOGINURL")
        test "$COOKIES" || { debug "login error"; return 1; }
        echo "$COOKIES"
    else 
        debug "no login info: anonymous upload"
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
