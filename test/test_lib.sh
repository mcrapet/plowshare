#!/bin/bash
set -e
MODULES="rapidshare megaupload 2shared"

ROOTDIR=$(dirname $(dirname "$(readlink -f "$0")"))
PICSDIR=$ROOTDIR/test/pics
MODULESDIR=$ROOTDIR/src/modules
EXTRASDIR=$MODULESDIR/extras
TESTSDIR=$ROOTDIR/test

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
    assert_return 1 "echo '$TEXT' | parse '^var5' 'var5 = \([[:alpha:]]*\)'"
}

test_debug() {
    assert_equal "" $(debug "test" 2>/dev/null)
    assert_equal "test" $(debug "test" 2>&1)
}

test_match() {
    assert_return 0 'match "^abc" "abcdef"'
    assert_return 0 'match "a[0-9]3" "a13"'
    assert_return 1 'match "^a[0-9]3" "xa13"'
}

test_ocr() {
    assert_equal "Hello world" "$(ocr < $PICSDIR/hello_world.gif 2>/dev/null)"
    assert_equal "XGXD" "$(ocr < $PICSDIR/badongo_xgxd.gif 2>/dev/null)"
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
