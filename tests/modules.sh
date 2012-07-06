#!/bin/bash
#
# Test functions for modules (see "modules" directory)
# Copyright (c) 2011-2012 Plowshare team
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

# Path to plow{down,up,del,list} scripts
SRCDIR=../src

# Test data
TEST_FILES=( 'up-down-del.t'
  'up-down-del+captcha.t'
  'single_link_download.t'
  'check_wrong_link.t')
TEST_LETTER=('T' 'R' 'S' 'C')
TEST_INDEX=(10 220 330 440)
TEST_TITLE=('*** Anonymous upload, download and delete'
  '*** Anonymous upload, download (with captcha) and delete'
  '*** Single URL anonymous download'
  '*** Check wrong link suite')

# plowdown
download() {
    $SRCDIR/download.sh --no-overwrite --max-retries=6 --timeout=400 "$@"
}

# plowup
upload() {
    $SRCDIR/upload.sh --max-retries=2 --printf='%u%t%D' "$@"
}

# plowdel
delete() {
    $SRCDIR/delete.sh -q "$@"
}

# plowlist - not used yet!
#list() {
#    $SRCDIR/list.sh -q "$@"
#}

stderr() {
    echo "$@" >&2
}

# Print test result
# $1: '$?' value
status() {
    local RET=$1
    if [ "$FANCY_OUTPUT" -ne 0 ]; then
        # based on /lib/lsb/init-functions
        RALIGN="\\r\\033[$[`tput cols`-6]C"
        OFF=$(tput op)
        if [ "$RET" -eq 0 ]; then
            GREEN=$(tput setaf 2)
            echo -e "${RALIGN}[${GREEN}DONE${OFF}]"
        else
            RED=$(tput setaf 1)
            echo -e "${RALIGN}[${RED}FAIL${OFF}]"
        fi
    else
        echo
    fi
    return $RET
}

# Is element contained in array
# $1: array
# $2: element to check
# $?: zero for success
exists()
{
    local -a ARRAY=( $(eval "echo \${$1[@]}") )
    local I
    for I in ${ARRAY[@]}; do

        # Compare exact tnum (ex:"S402")
        [ "$I" == "$2" ] && return 0

        # But accept one single lettre for all tests (ex:"S")
        [ "${#I}" -eq 1 -a "${2:0:1}" = "$I" ] && return 0

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
# $1: prefix name
# $2: block size (examples: 100k, 2M)
# $3: block count
# stdout: filename
create_temp_file() {
    NAME=$(mktemp "${1}.XXX")
    if [ -c '/dev/urandom' ]; then
        INPUT='/dev/urandom'
    else
        INPUT='/dev/zero'
    fi
    dd if=$INPUT of=$NAME bs=$2 count=${3:-1} 2>/dev/null
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

    local RET LOG_FILE LINKS OFILE DL_LINK DEL_LINK

    # Check for double-dash (no option)
    [ "$OPTS_UP" = '--' ] && OPTS_UP=
    [ "$OPTS_DN" = '--' ] && OPTS_DN=
    [ "$OPTS_DEL" = '--' ] && OPTS_DEL=

    RET=0
    LOG_FILE="$TEMP_DIR/${MODULE}.u.log"
    LINKS=$(upload -v4 $OPTS_UP "$MODULE" "$FILE" 2>"$LOG_FILE") || RET=$?
    if [ "$RET" -ne 0 ]; then
        # ERR_LINK_NEED_PERMISSIONS
        if [ "$RET" -eq 12 ]; then
            echo -n "skip up (need account)"
        # ERR_SYSTEM
        elif [ "$RET" -eq 8 ]; then
            echo -n "skip up (system failure)"
        # ERR_MAX_TRIES_REACHED
        elif [ "$RET" -eq 6 ]; then
            echo -n "up KO (max retries)"
        else
            echo -n "up KO"
        fi

        status 1
        stderr "ERR ($RET): plowup $OPTS_UP $MODULE $FILE"
        stderr "ERR ($RET): logfile: $LOG_FILE"
        return
    else
        rm -f "$LOG_FILE"
    fi

    # Should return "download_link \t delete_link
    DL_LINK=$(echo "$LINKS" | cut -d'	' -f1)
    DEL_LINK=$(echo "$LINKS" | cut -d'	' -f2)

    # Sanity check
    if [ -z "$DL_LINK" ]; then
        echo -n "up KO (fatal, need module rework)"
        status 1
        return
    fi

    echo -n "up ok > "

    # Check link
    download --check-link -q $OPTS_DN "$DL_LINK" >/dev/null || RET=$?
    if [ "$RET" -ne 0 ]; then
        # ERR_LINK_TEMP_UNAVAILABLE
        if [ "$RET" -eq 10 ]; then
            echo -n "check link KO (link not available)"
        else
            echo -n "check link KO"
        fi

        status 2
        stderr "ERR ($RET): plowdown --check-link $OPTS_DN $DL_LINK"
        return
    fi

    echo -n "check link ok > "

    LOG_FILE="$TEMP_DIR/${MODULE}.d.log"
    OFILE=$(download -v4 --temp-directory=$TEMP_DIR $OPTS_DN "$DL_LINK" 2>"$LOG_FILE") || RET=$?
    if [ "$RET" -ne 0 -o -z "$OFILE" ]; then
        # ERR_LINK_TEMP_UNAVAILABLE
        if [ "$RET" -eq 10 ]; then
            echo -n "down KO (link not available)"
        # ERR_MAX_WAIT_REACHED
        elif [ "$RET" -eq 5 ]; then
            echo -n "down KO (wait timeout)"
        # ERR_MAX_TRIES_REACHED
        elif [ "$RET" -eq 6 ]; then
            echo -n "down KO (max retries)"
        # ERR_CAPTCHA
        elif [ "$RET" -eq 7 ]; then
            echo -n "down KO (captcha solving failure)"
        # ERR_LINK_NEED_PERMISSIONS
        elif [ "$RET" -eq 12 ]; then
            echo -n "down KO (authentication required)"
        else
            echo -n "down KO"
        fi

        status 3
        stderr "ERR ($RET): plowdown $OPTS_DN $DL_LINK"
        stderr "ERR ($RET): logfile: $LOG_FILE"
        return
    else
        # Compare files
        diff -q "$FILE" "$OFILE" 2>&1 >/dev/null || stderr "ERR: uploaded and downloaded are binary different"
        rm -f "$OFILE" "$LOG_FILE"
    fi

    echo -n "down ok > "

    delete $OPTS_DEL "$DEL_LINK" || RET=$?
    # If delete function available (ERR_NOMODULE)
    if [ "$RET" -eq 2 ]; then
        echo -n "skip del (not available)"
    # ERR_LINK_NEED_PERMISSIONS
    elif [ "$RET" -eq 12 ]; then
        echo -n "skip del (need account)"
    elif [ "$RET" -ne 0 ]; then
        echo -n "del KO"
        status 4
        stderr "ERR ($RET): plowdel $OPTS_DEL $DEL_LINK"
        return
    else
        echo -n "del ok"
    fi

    status 0
    return
}

# $1: url
# $2: filename
# $3: plowdown options ("--" means no option)
# $?: zero on success, positive for error
test_signle_down() {
    local LINK=$1
    local FILENAME=$2
    local OPTS_DN=$3
    local F

    # Check for double-dash (no option)
    [ "$OPTS_DN" = '--' ] && OPTS_DN=

    RET=0
    F=$(download -q --temp-directory=$TEMP_DIR $OPTS_DN "$LINK") || RET=$?
    if [ "$RET" -ne 0 ]; then
        # ERR_LINK_NEED_PERMISSIONS
        if [ "$RET" -eq 12 ]; then
            echo -n "down KO (authentication required)"
        else
            echo -n "down KO"
        fi

        status 1
        stderr "ERR ($RET): plowdown $OPTS_DN $LINK"
        return
    fi

    rm -f "$F"
    echo -n "down ok"

    status 0
    return
}

# $1: url
# $2: plowdown options ("--" means no option)
# $?: zero on success, positive for error
test_check_wrong_link() {
    local LINK=$1
    local OPTS_DN=$2

    # Check for double-dash (no option)
    [ "$OPTS_DN" = '--' ] && OPTS_DN=

    RET=0
    download --check-link -q $OPTS_DN "$LINK" >/dev/null || RET=$?

    # ERR_LINK_DEAD=13
    if [ "$RET" -ne 13 ]; then
        echo -n "check link KO"
        status 2
        stderr "ERR ($RET): plowdown --check-link $OPTS_DN $LINK"
        return
    fi

    echo -n "check link ok (link dead as expected)"

    status 0
    return
}

usage() {
cat << EOF
Usage: $0 [options] [tnum...]

Testing options (if none specified all tests are run):
 -l         list available tests <tnum> and exit

General options:
 -h         display this help and exit
 -d         disable fancy output (uses tput)
EOF

#Single test options: [NOT IMPLEMENTED YET!]
# -p <n>     number of passes (default is 1)
# -r <retry> number of retries when failed (default is 0)
}

##
#  Main
##

TEMP_DIR=$(gettemp)

# stdout is a color terminal ?
FANCY_OUTPUT=0
if [ -t 1 ]; then
    if [[ "$(tput colors)" -ge 8 ]]; then
        FANCY_OUTPUT=1
    fi
fi

TESTOP=te
PASS=1
TEST_FILESIZES=( '200k' '2M' '5M' )
TEST_ITEMS=()

# parse command line options (getopts is bash builtin)
while getopts "hldp:" OPTION
do
    case $OPTION in
        l) TESTOP='li'
           ;;
        d) FANCY_OUTPUT=0
           ;;
        p) PASS=$OPTARG
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
    echo "${TEST_TITLE[0]}"
    while readx M O1 O2 O3; do
        echo "${TEST_LETTER[0]}$i: $M ($O1)"
        let i++
    done < "${TEST_FILES[0]}"

    let i=${TEST_INDEX[1]}
    echo "${TEST_TITLE[1]}"
    while readx M O1 O2 O3; do
        echo "${TEST_LETTER[1]}$i: $M ($O1)"
        let i++
    done < "${TEST_FILES[1]}"

    let i=${TEST_INDEX[2]}
    echo "${TEST_TITLE[2]}"
    while readx URL F O1; do
        echo "${TEST_LETTER[2]}$i: $URL ($O1)"
        let i++
    done < "${TEST_FILES[2]}"

    let i=${TEST_INDEX[3]}
    echo "${TEST_TITLE[3]}"
    while readx URL O1; do
        echo "${TEST_LETTER[3]}$i: $URL ($O1)"
        let i++
    done < "${TEST_FILES[3]}"

else
    # FIXME: Do 1 pass for now..
    NAME="plowshare-$$"
    FILE1=$(create_temp_file "$NAME" 200k 1)

    # Trap CTRL+C
    trap "{ rm ${NAME}*; exit 1; }" INT

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
        while readx M O1 O2 O3; do
            if exists TEST_ITEMS "${TEST_LETTER[1]}$i"; then
                echo -n "testing $M ..."
                test_case_up_down_del "$FILE1" $M "$O1" "$O2" "$O3" || true
                let n++
            fi
            let i++
        done < "${TEST_FILES[1]}"

        let i=${TEST_INDEX[2]}
        while readx URL F O1; do
            if exists TEST_ITEMS "${TEST_LETTER[2]}$i"; then
                echo -n "testing $URL ..."
                test_signle_down "$URL" "$F" "$O1" || true
                let n++
            fi
            let i++
        done < "${TEST_FILES[2]}"

        let i=${TEST_INDEX[3]}
        while readx URL O1; do
            if exists TEST_ITEMS "${TEST_LETTER[3]}$i"; then
                echo -n "testing $URL ..."
                test_check_wrong_link "$URL" "$O1" || true
                let n++
            fi
            let i++
        done < "${TEST_FILES[3]}"

        if [ "$n" -eq 0 ]; then
            echo "error: bad test name \"${TEST_ITEMS[0]}\""
        fi

    # Perform all tests here
    else
        echo "Testing all modules. This will be long, you can go away take a coffee..."
        read -r -p "Are you sure (y/N)? " -n 1 CONT
        test "$CONT" && echo
        [[ "$CONT" = [Yy] ]] || exit 0

        while readx M O1 O2 O3; do
            echo -n "testing $M ..."
            test_case_up_down_del "$FILE1" $M "$O1" "$O2" "$O3" || true
        done < "${TEST_FILES[0]}"
        while readx M O1 O2 O3; do
            echo -n "testing $M ..."
            test_case_up_down_del "$FILE1" $M "$O1" "$O2" "$O3" || true
        done < "${TEST_FILES[1]}"
        while readx URL F O1; do
            echo -n "testing $URL ..."
            test_signle_down "$URL" "$F" "$O1" || true
        done < "${TEST_FILES[2]}"
        while readx URL O1; do
            echo -n "testing $URL ..."
            test_check_wrong_link "$URL" "$O1" || true
        done < "${TEST_FILES[3]}"
    fi

    rm -f "$FILE1"
fi
