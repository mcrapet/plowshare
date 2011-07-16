#!/bin/bash
#
# Test functions for modules (see "modules" directory)
# Copyright (c) 2011 Plowshare team
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


# Note: 'readlink -f' does not exist on BSD
ROOTDIR=$(dirname $(dirname "$(readlink -f "$0")"))
SRCDIR="$ROOTDIR/src"

# Test data
TEST_FILES=( "up-down-del.t" "single_link_download.t" )
TEST_LETTER=('T' 'S')
TEST_INDEX=(10 500)


# plowdown
download() {
    $SRCDIR/download.sh -q --no-overwrite --no-arbitrary-wait \
        --max-retries=50 --timeout=600 "$@"
}

# plowup
upload() {
    $SRCDIR/upload.sh -q "$@"
}

# plowdel
delete() {
    $SRCDIR/delete.sh -q "$@"
}

# plowlist
list() {
    $SRCDIR/list.sh -q "$@"
}

stderr() {
    echo "$@" >&2;
}

# Is element contained in array
# $1: array
# $2: element to check
# $?: zero for success
exists()
{
    local -a ARRAY=( $(eval "echo \${$1[@]}") )
    local i
    for i in ${ARRAY[@]}; do

        # Compare exact tnum (ex:"S504")
        [ "$i" == "$2" ] && return 0

        # But accept one single lettre for all tests (ex:"S")
        [ "${#i}" -eq 1 -a "${2:0:1}" = "$i" ] && return 0

    done
    return 1
}

# Multi-read function (read ${#ARGV} lines)
readx() {
    local N=1
    local RET=0

    while [ "$N" -le $# -a "$RET" -eq 0 ]; do
        read LINE
        RET=$?
        ARG=$(eval echo \$$N)
        eval "$ARG=\$LINE"
        # Skip empty lines and comments
        if [ -n "$LINE" -a "${LINE:0:1}" != "#" ]; then
            (( N++ ))
        fi
    done
    return $RET
}

# Create a random file of a specific size
# $1: block size (examples: 100k, 2M)
# $2: block count
# stdout: filename
create_temp_file() {
    NAME=$(mktemp plowshare-$$.XXX)
    if [ -c '/dev/urandom' ]; then
        INPUT='/dev/urandom'
    else
        INPUT='/dev/zero'
    fi
    dd if=$INPUT of=$NAME bs=$1 count=${2:-1} 2>/dev/null
    echo "$NAME"
}

# Get temporary directory (found this in ffmpeg)
gettemp() {
    local TEMP=${TMPDIR:=$TEMPDIR}
    TEMP=${TEMP:=$TMP}
    TEMP=${TEMP:=/tmp}
    echo "$TEMP"
}

# $1: test file
# $2: module name
# $3: plowup options ("--" means no option)
# $4: plowdown options ("--" means no option)
# $5: plowdel options ("--" means no option)
# $?: zero on success, positive for error
test_case_up_down_del() {
    local FILE=$1
    local MODULE=$2
    local OPTS_UP=$3
    local OPTS_DN=$4
    local OPTS_DEL=$5

    # Check for double-dash (no option)
    [ "${OPTS_UP:0:2}" = '--' ] && OPTS_UP=
    [ "${OPTS_DN:0:2}" = '--' ] && OPTS_DN=
    [ "${OPTS_DEL:0:2}" = '--' ] && OPTS_DEL=

    RET=0
    LINKS=$(upload $OPTS_UP "$MODULE" "$FILE") || RET=$?
    if [ "$RET" -ne 0 ]; then
        echo "up KO"
        stderr "ERR ($RET): plowup $OPTS_UP $MODULE $FILE"
        return 1
    fi

    # Should return "download_link (delete_link)
    DL_LINK=$(echo "$LINKS" | cut -d' ' -f1)
    DEL_LINK=$(echo "$LINKS" | cut -d'(' -f2 | cut -d')' -f1)

    echo -n "up ok > "

    # Check link
    download --check-link $OPTS_DN "$DL_LINK" >/dev/null || RET=$?
    if [ "$RET" -ne 0 ]; then
        echo "check link KO"
        stderr "ERR ($RET): plowdown --check-link $OPTS_DN $DL_LINK"
        return 2
    fi

    echo -n "check link ok > "

    local FILENAME=$(download --temp-directory=$TEMP_DIR $OPTS_DN "$DL_LINK") || RET=$?
    if [ "$RET" -ne 0 ]; then
        echo "down KO"
        stderr "ERR ($RET): plowdown $OPTS_DN $DL_LINK"
        return 3
    else
        rm -f "$FILENAME"
    fi

    echo -n "down ok > "

    delete $OPTS_DEL "$DEL_LINK" >/dev/null || RET=$?
    # If delete function available (ERROR_CODE_NOMODULE)
    if [ "$RET" -eq 2 ]; then
        echo "skip del (not available)"
    # ERR_LINK_NEED_PERMISSIONS=12
    elif [ "$RET" -eq 12 ]; then
        echo "skip del (need account)"
    elif [ "$RET" -ne 0 ]; then
        echo "del KO"
        stderr "ERR ($RET): plowdel $OPTS_DEL $DEL_LINK"
        return 4
    else
        echo "del ok"
    fi

    return 0
}

# $1: url
# $2: filename
# $3: plowdown options ("--" means no option)
# $?: zero on success, positive for error
test_signle_down() {
    local LINK=$1
    local FILENAME=$2
    local OPTS_DN=$3

    # Check for double-dash (no option)
    [ "${OPTS_DN:0:2}" = '--' ] && OPTS_DN=

    RET=0
    local F=$(download --temp-directory=$TEMP_DIR $OPTS_DN "$LINK") || RET=$?
    if [ "$RET" -ne 0 ]; then
        echo "down KO"
        stderr "ERR ($RET): plowdown $OPTS_DN $LINK"
        return 1
    fi

    rm -f "$F"
    echo "down ok"

    return 0
}

usage() {
cat << EOF
Usage: $0 [options] [tnum...]

Testing options (if none specified all tests are run):
 -l         list available tests <tnum> and exit

General options:
 -h         display this help and exit
 -c         enable fancy output (uses tput) [NOT IMPLEMENTED YET!]
EOF

#Single test options: [NOT IMPLEMENTED YET!]
# -p <n>     number of passes (default is 1)
# -r <retry> number of retry when failed (default is 0)
}

##
#  Main
##

TEMP_DIR=$(gettemp)

TESTOP=te
PASS=1
TEST_FILESIZES=( '200k' '2M' '5M' )
TEST_ITEMS=()

# parse command line options
while getopts "hlct:p:r:" OPTION
do
    case $OPTION in
        l) TESTOP='li'
           ;;
        ?|h) usage
           exit 1
           ;;
    esac
done

shift $((OPTIND-1))

# Remaining arguments are test case number
for ARG in "$@"; do
    FOUND=0
    for LETTER in ${TEST_LETTER[@]}; do
        ARG="`echo $ARG | tr '[:lower:]' '[:upper:]'`"
        if [ "${ARG:0:1}" = $LETTER ]; then
            TEST_ITEMS=( "${TEST_ITEMS[@]}"  "$ARG" )
            FOUND=1
            break
        fi
    done
    test $FOUND -eq 0 && echo "wrong test number: $ARG, skipping"
done

if [ $TESTOP = 'li' ]; then
    let i=${TEST_INDEX[0]}
    while readx M O1 O2 O3; do
        echo "T$i: $M ($O1)"
        let i++
    done < "${TEST_FILES[0]}"

    let i=${TEST_INDEX[1]}
    while readx URL F O1; do
        echo "S$i: $URL ($O1)"
        let i++
    done < "${TEST_FILES[1]}"

else
    FILE1=$(create_temp_file 200k 1)

    # Perform tests specified in TEST_ITEMS array
    if [ ${#TEST_ITEMS[@]} -ne 0 ]; then
        let n=0

        let i=${TEST_INDEX[0]}
        while readx M O1 O2 O3; do
            if exists TEST_ITEMS "${TEST_LETTER[0]}$i"; then
                echo -n "testing $M ..."
                test_case_up_down_del "$FILE1" $M "$O1" "$O2" "$O3" || true
                let n++
            fi
            let i++
        done < "${TEST_FILES[0]}"

        let i=${TEST_INDEX[1]}
        while readx URL F O1; do
            if exists TEST_ITEMS "${TEST_LETTER[1]}$i"; then
                echo -n "testing $URL ..."
                test_signle_down "$URL" $F "$O1" || true
                let n++
            fi
            let i++
        done < "${TEST_FILES[1]}"

        if [ "$n" -eq 0 ]; then
            echo "error: bad test name \"${TEST_ITEMS[0]}\""
        fi

    # Perform all tests here
    else

        echo "Testing all modules. This will be long, you can go away take a coffee..."
        read -p "Are you sure (y/N)? " -n 1 CONT
        if [ "$CONT" != 'y' -a "$CONT" != 'Y' ]; then
            exit 0
        fi
        echo

        while readx M O1 O2 O3; do
            echo -n "testing $M ..."
            test_case_up_down_del "$FILE1" $M "$O1" "$O2" "$O3" || true
        done < "${TEST_FILES[0]}"
        while readx URL F O1; do
            echo -n "testing $URL ..."
            test_signle_down "$URL" $F "$O1" || true
        done < "${TEST_FILES[1]}"
    fi

    rm -f "$FILE1"
fi

