#!/bin/bash
#
# Endless loop to use a file as download queue
#
# Example: plowdown_loop.sh [OUTPUT_DIR] [QUEUE_FILE]
#
set -e
QUEUE_FILE=${1:-"$HOME/.plowshare/download.queue"}
DESTDIR=${2:-"$HOME/.plowshare/download"}
SLEEP="1m"

debug() { echo "$@" >&2; }

mkdir -p "$(dirname "$QUEUE_FILE")"
touch "$QUEUE_FILE"
debug "queue file: $QUEUE_FILE"
mkdir -p "$DESTDIR"
debug "destination directory: $DESTDIR"

trap "kill 0" SIGTERM SIGINT EXIT
while true; do  
	plowdown -m "$QUEUE_FILE" -o "$DESTDIR" || true 
	echo "sleeping: $SLEEP"
 	sleep "$SLEEP"
done
