#!/bin/bash
#
# Launch parallel plowdown processes for different websites
#
# Example: plowdown_parallel.sh FILE_WITH_ONE_LINK_PER_LINE
#
set -e
 
debug() { echo "$@" >&2; }

wait_pids() {
  local -a PIDS=()
  for PID in "$@"; do 
    PIDS[$PID]=$PID 
  done
  debug "Waiting for: ${PIDS[*]}"
  while test ${#PIDS[*]} -ne 0; do
    for PID in "${PIDS[@]}"; do
      kill -0 $PID 2>/dev/null || { 
        wait $PID && unset PIDS[$PID] && debug "finished: $PID" 
      }
    done
    sleep 1
  done
}

get_modules() {
  MODULES=$(plowdown --get-module "$1")
  INFO=$(echo "$MODULES" | paste - "$1")
  
  for MODULE in $(echo "$MODULES" | sort -u); do
    URLS=$(echo "$INFO" | awk "\$1 == \"$MODULE\"" | cut -f2- | xargs)
    echo "$MODULE $URLS"
  done
}

# Main

test $# -ge 1 || { debug "Usage: $(basename $0) FILEWITHLINKS"; exit 1; }
INFILE=$1
trap "kill 0" SIGINT SIGTERM EXIT
PIDS=()

while read MODULE URLS; do
  debug "Module $MODULE urls: $URLS"
  plowdown $URLS &
  PIDS=("${PIDS[@]}" $!)
done < <(get_modules "$INFILE")

wait_pids "${PIDS[@]}"
