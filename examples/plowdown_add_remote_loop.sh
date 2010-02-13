#!/bin/bash
#
# Script to add links to the queue on a server running plowdown_loop.sh (using SSH)
#
# Example: plowdown_add_remote_loop.sh SERVER REMOTE_QUEUE_FILE LINK1 [LINK2] ...
#
set -e

debug() { echo "$@" >&2; }

# remove duplicate (and keep order)
remove_duplicate() { awk '!x[$0]++'; } 

SERVER=$1
REMOTE_QUEUE_FILE=${2:-"$HOME/.plowshare/download.queue"}

test $# -ge 3 || { 
  debug "Usage: $(basename "$0") SERVER REMOTE_QUEUE_FILE LINK1 [LINK2] ..."
  exit 2
}

shift 2
debug "server: $SERVER"
debug "remote queue fule: $REMOTE_QUEUE_FILE" 
for LINK in "$@"; do
  debug "sending link: $LINK" 
  echo $LINK
done | ssh "$SERVER" "touch \"$REMOTE_QUEUE_FILE\"
                      LINKS=\$(cat \"$REMOTE_QUEUE_FILE\" - | awk '!x[\$0]++')
                      echo \"\$LINKS\" > \"$REMOTE_QUEUE_FILE\""
