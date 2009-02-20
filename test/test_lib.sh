#!/bin/bash
set -e
ROOTDIR=$(dirname $(dirname "$(readlink -f "$0")"))
PICSDIR=$ROOTDIR/test/pics

source $ROOTDIR/src/lib.sh
source $ROOTDIR/test/lib.sh

test_parse() {
    TEXT="var1 = 1
var2 = 2
another line
var3 = 33
"
    assert_match "1" $(echo "$TEXT" | parse "var1" "var1 = \([[:digit:]]*\)")
    assert_match "33" $(echo "$TEXT" | parse "^var3" "var3 = \([[:digit:]]*\)")
    assert_return 1 "echo '$TEXT' | parse '^var5' 'var5 = \([[:digit:]]*\)'"
}

test_match() {
    assert_return 0 'match "^abc" "abcdef"'
    assert_return 0 'match "a[0-9]3" "a13"'
    assert_return 1 'match "^a[0-9]3" "xa13"'
}

test_ocr() {
    assert_equal "Hello world" "$(ocr < $PICSDIR/hello_world.gif 2>/dev/null)"
    assert_equal "PEZ3" "$(ocr < $PICSDIR/captcha_pez3.gif 2>/dev/null)"
}

run_tests "$@"
