#!/bin/bash
set -e
MODULES="rapidshare megaupload 2shared"

ROOTDIR=$(dirname $(dirname "$(readlink -f "$0")"))
PICSDIR=$ROOTDIR/test/pics
MODULESDIR=$ROOTDIR/src/modules
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
    assert_equal "PEZ3" "$(ocr < $PICSDIR/captcha_pez3.gif 2>/dev/null)"
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
    OPTIONS="a:,auth:,AUTH,USER:PASSWORD q,quiet,QUIET ,level:,LEVEL,INTEGER"
    eval "$(process_options "$OPTIONS" --auth=user:password -q arg1 arg2 --level=5)"
    assert_equal user:password $AUTH
    assert_equal 1 $QUIET
    assert_equal 5 $LEVEL
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

test_post_login() {
    AUTH=$(cat $TESTSDIR/.rapidshare-auth)
    FREEZONE_LOGIN_URL="https://ssl.rapidshare.com/cgi-bin/collectorszone.cgi"       
    LOGIN_DATA='username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$FREEZONE_LOGIN_URL" 2>/dev/null)
    assert_match "\.rapidshare\.com" "$COOKIES"
}

test_get_module() {
    RAPIDSHARE_URL="http://www.rapidshare.com/files/86545320/Tux-Trainer_25-01-2008.rar"
    MEGAUPLOAD_URL="http://www.megaupload.com/?d=ieo1g52v"
    SHARED_URL="http://www.2shared.com/file/4446939/c9fd70d6/Test.html"
    for SCRIPT in $MODULESDIR/*; do
        source $SCRIPT
    done    
    assert_equal "rapidshare" $(get_module $RAPIDSHARE_URL "$MODULES") 
}

run_tests "$@"
