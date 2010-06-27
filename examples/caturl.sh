#!/bin/bash
#
# Grep URLs contained as input text (usually a web page).
# Creation date: 27/06/2010 11:53

FILENAME=

if [ $# -ge 1 ]; then
    case $1 in
        '--help')
            echo "Usage: ${0##*/} [FILE]"
            exit 0
            ;;
        '-')
            FILENAME=
            ;; # stdin
        -*)
            echo "err: bad option, see help" 1>&2
            exit 1
            ;;
        *)
            test -f "$1" || { echo "err: \`$1' is not a file" 1>&2; exit 1; }
            FILENAME="$1"
            ;;
    esac
fi

[ $# -ge 2 ] && echo "wrn: too many parameters, ignoring" 1>&2

test -z "$FILENAME" && CMD='cat' || CMD='cat "$FILENAME"'
eval "$CMD" | sed  -e 's/>/>\n/g' | \
    sed -ne 's/^.*<[aA] .*[Hh][Rr][Ee][Ff]=["'\'']\?\([^"'\''>]*\).*$/\1/gp'

exit 0
