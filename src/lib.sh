#!/bin/bash
#
# Library for downshare.

# Echo text to standard error.
#
debug() { 
    echo "$@" >&2
}

# Check existance of executable in path
#
check_exec() {
    type -P $1 > /dev/null || { debug "$2"; exit 1; }
}

# Get first line that matches a regular expression and extract string from it.
#
# $1: POSIX-regexp to filter (get only the first matching line).
# $2: POSIX-regexp to match (use parentheses) on the matched line.
#
parse() { 
    sed -n "/$1/ s/^.*$2.*$/\1/p" | head -n1 
}

# Check if a string ($2) matches a regexp ($1)
#
match() { 
    grep -q "$1" <<< "$2"
}

# Login to and return cookies
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
        debug "using cookies: $COOKIES"
        echo "$COOKIES"
    else 
        debug "no login info: anonymous upload"
    fi
}

# OCR of an image. Write OCRed text to standard input
#
# Standard input: image to OCR 
ocr() {
    check_exec "convert" "convert not found (install imagemagick)"
    check_exec "tesseract" "tesseract not found (install tesseract-ocr)"
    TEMP=$(tempfile -s ".tif")
    TEMP2=$(tempfile -s ".txt")
    convert - tif:- > $TEMP
    tesseract $TEMP ${TEMP2/%.txt}
    TEXT=$(cat $TEMP2 | xargs)
    rm -f $TEMP $TEMP2
    echo $TEXT
}
