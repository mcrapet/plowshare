#!/bin/bash

# Check that $1 is equal to $2.
assert_equal() {
    if ! test "$1" = "$2"; then
        echo "failed!"
        echo "  assert_equal failed: $1 != $2"
        return 1
    fi
}

# Check that regexp $1 matches $2.
assert_match() {
    if ! grep -q "$1" <<< "$2"; then
        echo "failed!"
        echo "  assert_match failed: regexp $1 does not match $2"
        return 1
    fi
}

# Check that execution of $2-N return code $1
assert_return() {
    eval "$2" &>/dev/null
    RETCODE=$?
    if ! test "$1" = "$RETCODE"; then
        echo "failed!"
        echo "  assert_return failed: $1 != $RETCODE" 
        return 1
    fi
}

# Check that $1 is not a empty stringu
assert() {
  if ! test "$1"; then
    echo "failed!"
    echo "  assert failed"
    return 1
  fi
}

# Run a test
run() {
  echo -n "$1... "
  "$@" && echo "ok" || echo "failed!"
}

# Run tests (run all if none is given)
run_tests() {
    if test $# -eq 0; then 
        TESTS=$(set | grep "^test_" | awk '$2 == "()"' | awk '{print $1}' | xargs)
    else        
        TESTS="$@"
    fi 
    for TEST in $TESTS; do
        run $TEST
    done
}
