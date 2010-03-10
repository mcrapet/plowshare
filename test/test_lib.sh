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
#

set -e

MODULES="rapidshare megaupload 2shared"

ROOTDIR=$(dirname $(dirname "$(readlink -f "$0")"))
PICSDIR=$ROOTDIR/test/pics
MODULESDIR=$ROOTDIR/src/modules
TESTSDIR=$ROOTDIR/test
LIBDIR=$ROOTDIR/src

source "$LIBDIR/lib.sh"
source "$TESTSDIR/lib.sh"

test_parse() {
    TEXT="var1 = 1
var2 = 2
another line
var3 = 33
"
    assert_match "1" $(echo "$TEXT" | parse "var1" "var1 = \([[:digit:]]*\)")
    assert_match "33" $(echo "$TEXT" | parse "^var3" "var3 = \([[:digit:]]*\)")
    assert_return 1 "echo '$TEXT' | parse '^var5' 'var5 = \([[:alpha:]]*\)'"
}

test_debug() {
    assert_equal "" $(log_debug "test" 2>/dev/null)
    assert_equal "test" $(log_debug "test" 2>&1)
}

test_match() {
    assert_return 0 'match "^abc" "abcdef"'
    assert_return 0 'match "a[0-9]3" "a13"'
    assert_return 0 'match "a[[:digit:]]3" "a13"'
    assert_return 1 'match "^a[0-9]3" "xa13"'
    assert_return 0 'match "ab\|cd" "*about*"'
    assert_return 0 'match "ab\|c d" "--c d--"'
    assert_return 0 'match "//" "a//b"'
    assert_return 0 'match "[3-6]\{2\}" "for 567 bar"'
    assert_return 1 'match "[3-6]\{3\}" "for 567 bar"'
}

test_ocr() {
    assert_equal "Hello world" "$(ocr < $PICSDIR/hello_world.gif 2>/dev/null)"
    assert_equal "XGXD" "$(ocr < $PICSDIR/badongo_xgxd.gif 2>/dev/null)"
    assert_equal "XGXD" "$(ocr upper < $PICSDIR/badongo_xgxd.gif 2>/dev/null)"
    assert_equal "DTE5" "$(ocr < $PICSDIR/megaupload_dte5.gif 2>/dev/null)"
    assert_equal "3909" "$(cat $PICSDIR/netload.in_3909.png | perl $LIBDIR/strip_single_color.pl | ocr digit 2>/dev/null)"
    #assert_equal "1554" "$(cat $PICSDIR/loadfiles.in_1554.jpg | convert - -crop 36x14+22+5 gif:- | \
    #                       perl $LIBDIR/strip_grey.pl | ocr digit 2>/dev/null | tr -d ' ')"
    assert_equal "8+2=" "$(cat $PICSDIR/freakshare_8plus2.png | ocr digit_ops 2>/dev/null)"
}

test_check_exec() {
    assert_return 0 'check_exec ls'
    assert_return 0 'check_exec echo'
    assert_return 1 'check_exec this_command_shouldnt_exist_on_a_sane_system'
}

test_check_function() {
    assert_return 0 'check_function assert_return'
    unset non_existing_function
    assert_return 1 'check_function non_existing_function'
}

test_process_options() {
    OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Authentication
QUIET,q,quiet,,Don't print errors
!LEVEL,l:,level:,INTEGER,Set level
!VALUE,v:,value:,STRING,Set value
"
    eval "$(process_options test_lib "$OPTIONS" \
        -a "user : password" -q --level="5 a" --value="1 \" 2" arg1 arg2)"
    assert_equal "user : password" "$AUTH"
    assert_equal 1 "$QUIET"
    assert_equal "" "$LEVEL"
    assert_equal 2 "${#UNUSED_OPTIONS[@]}"
    assert_equal '--level=5 a' "${UNUSED_OPTIONS[0]}"
    assert_equal "--value=1 \" 2" "${UNUSED_OPTIONS[1]}"
    assert_equal arg1 $1
    assert_equal arg2 $2
}

test_create_tempfile() {
    TEMP=$(create_tempfile)
    assert_return 0 "test -e $TEMP"
    rm -f $TEMP
    TEMP=$(create_tempfile ".txt")
    assert_return 0 "test -e $TEMP"
    assert_match "\.txt$" "$TEMP"
    rm -f $TEMP
}

#test_megaupload_ocr() {
#    CAPTCHA=$(megaupload_ocr "$PICSDIR/megaupload_prz2.gif")
#    assert_equal "PRZ2" $CAPTCHA
#}

run_tests "$@"
