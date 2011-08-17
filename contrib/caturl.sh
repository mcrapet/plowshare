#!/bin/bash
#
# Grep URLs contained as input text (usually a web page).
# Copyright (c) 2010 Matthieu Crapet
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

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
