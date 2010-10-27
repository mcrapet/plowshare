#!/bin/bash
#
# Common assert test functions
# Copyright (c) 2010 Arnau Sanchez
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

# Check that $1 is equal to $2.
assert_equal() {
    if ! test "$1" = "$2"; then
        echo "assert_equal failed: '$1' != '$2'"
        return 1
    fi
}

# Check that $1 is equal to $2 and show diff if different.
assert_equal_with_diff() {
    if ! test "$1" = "$2"; then
        echo "assert_equal_with_diff failed"
        diff -u -i <(echo "$1") <(echo "$2")
        return 1
    fi
}

# Check that $1 is not equal to $2.
assert_not_equal() {
    if test "$1" = "$2"; then
        echo "assert_not_equal failed: $1 == $2"
        return 1
    fi
}


# Check that regexp $1 matches $2.
assert_match() {
    if ! grep -q "$1" <<< "$2"; then
        echo "assert_match failed: regexp $1 does not match $2"
        return 1
    fi
}

# Check that execution of $2-N return code $1
assert_return() {
    eval "$2" &>/dev/null && RETCODE=$? || RETCODE=$?
    if ! test "$1" = "$RETCODE"; then
        echo "assert_return failed: $1 != $RETCODE"
        return 1
    fi
}

# Check that $1 is not a empty string
assert() {
  if ! test "$1"; then
    echo "assert failed"
    return 1
  fi
}

# Run a test
run() {
    echo -n "$1... "
    local RETVAL=0
    "$@" || RETVAL=$?
    if test $RETVAL -eq 0; then
        echo "ok"
    elif test $RETVAL -eq 255; then
        echo "skipped"
    else
        echo "failed!"
        return 1
    fi
}

# Run tests (run all if none is given)
run_tests() {
    local RETVAL=0
    if test $# -eq 0; then
        TESTS=$(set | grep "^test_" | awk '$2 == "()"' | awk '{print $1}' | xargs)
    else
        TESTS="$@"
    fi
    for TEST in $TESTS; do
        run $TEST || RETVAL=1
    done
    return $RETVAL
}
