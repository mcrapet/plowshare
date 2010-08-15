#!/bin/bash
#
# Launch parallel plowdown processes for different websites
#
# Example: plowdown_parallel.sh FILE_WITH_ONE_LINK_PER_LINE [PLOWDOWN_OPTIONS]
#
set -e
 
debug() { echo "$@" >&2; }

get_modules() {
  MODULES=$(plowdown --get-module "$1")
  INFO=$(echo "$MODULES" | paste - "$1")
  
  for MODULE in $(echo "$MODULES" | sort -u); do
    URLS=$(echo "$INFO" | awk "\$1 == \"$MODULE\"" | cut -f2- | xargs)
    echo "$MODULE $URLS"
  done
}

# Main

test $# -ge 1 || { 
  debug "Usage: $(basename $0) FILE_WITH_LINKS"
  exit 1
}
INFILE=$1
shift
trap "kill 0" SIGINT SIGTERM EXIT

while read MODULE URLS; do
  debug "Module $MODULE: $URLS"
  plowdown "$@" $URLS &
done < <(get_modules "$INFILE")

wait
