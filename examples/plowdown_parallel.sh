#/bin/bash
#
# Launch parallel plowdown processes for different websites
#
# This is file is part of plowshare.
#
# plowdown_parallel.sh FILE_WITH_ONE_LINK_PER_LINE
#

set -e
 
debug() { echo "$@" >&2; }

groupby() {
  local PREDICATE=$1
  local RETURN_FUNC=$2
  local LAST=
  local FIRST=1
  
  while read LINE; do
    local VALUE=$(echo $LINE | eval $PREDICATE)
    local RETURN=$(echo $LINE | eval $RETURN_FUNC)
    if test "$FIRST" = "1"; then
      echo -n "$VALUE: $RETURN"
      FIRST=0      
    elif test "$LAST" = "$VALUE"; then
      echo -n " $RETURN"
    else
      echo
      echo -n "$VALUE: $RETURN"
    fi
    LAST=$VALUE
  done
  test $FIRST=0 && echo
}

cleanup() {
  local PIDS=($(ps x -o "%p %r" | awk "\$1 != $$ && \$2 == $$" |
    awk '{print $1}' | xargs))
  debug; debug "cleanup: pids ${PIDS[*]}"
  for PID in ${PIDS[*]}; do
    kill -0 $PID 2>/dev/null && kill -TERM $PID 
  done
  debug "cleanup: done"
}

str2array() {
  echo $1 | xargs -n1 | xargs -i  echo '[{}]="{}"' | xargs
}

wait_pids() {
  declare -a PIDS="($(str2array "$1"))"
  debug "Waiting for: ${PIDS[*]}"
  while test ${#PIDS[*]} -ne 0; do
    for PID in ${PIDS[*]}; do
      kill -0 $PID 2>/dev/null || 
        { wait $PID && unset PIDS[$PID] && debug "finished: $PID"; }
    done
    sleep 1
  done
}

get_modules() {
  cat $INFILE | while read URL; do
    MODULE=$(plowdown --get-module $URL)
    echo "$MODULE $URL"
  done | sort -k1 | groupby "cut -d' ' -f1" "cut -d' ' -f2"
}

INFILE=$1
PIDS=()
while read MODULE URLS; do
  debug "Run: plowdown $URLS"
  plowdown $URLS &
  PID=$!
  PIDS=(${PIDS[*]} $PID)
done < <(get_modules)

trap cleanup SIGINT SIGTERM
wait_pids "${PIDS[*]}"
