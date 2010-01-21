#/bin/bash
#
# Launch parallel plowdown processes for different websites
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
  echo
}

cleanup() {
  ps awx > a.a
  local PIDS=($(ps x -o  "%p %r" | awk "\$1 != $$ && \$2 == $$" | 
    awk '{print $1}' | xargs))
  debug "cleanup: pids ${PIDS[*]}"
  for PID in ${PIDS[*]}; do
    kill -0 $PID 2>/dev/null && kill -TERM $PID 
  done
  sleep 2
  for PID in ${PIDS[*]}; do
    kill -0 $PID 2>/dev/null && kill -9 $PID 2>/dev/null
  done
  debug "cleanup: done"
}

INFILE=$1
PIDS=()
while read MODULE URLS; do
  debug "Run: plowdown $URLS"
  plowdown $URLS &
  PID=$!
  PIDS[$PID]=$PID
done < <(cat $INFILE | while read URL; do
           MODULE=$(plowdown --get-module $URL)
            echo "$MODULE $URL"
         done | sort -k1 | groupby "cut -d' ' -f1" "cut -d' ' -f2")

trap cleanup SIGINT SIGTERM

while test ${#PIDS[*]} -ne 0; do
  #debug "Waiting for pids: ${PIDS[*]}"
  for PID in ${PIDS[*]}; do
    kill -0 $PID 2>/dev/null || { wait $PID && unset PIDS[$PID]; }
  done
  sleep 1
done 
