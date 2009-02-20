#!/bin/bash
TESTSDIR=$(dirname "$(readlink -f "$0")")/test

$TESTSDIR/test_lib.sh
$TESTSDIR/test_functional.sh
