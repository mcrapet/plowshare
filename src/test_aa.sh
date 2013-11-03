#!/bin/bash

#http://unix.stackexchange.com/questions/56815/how-to-initialize-a-read-only-global-associative-array-in-bash

function foobar {
  declare -rgA 'FOOBAR=( [foo]=bar )'
}

foobar
declare -p FOOBAR

