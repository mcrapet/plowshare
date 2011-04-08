#!/bin/bash
#
# Endless loop to use a file as download queue
# Copyright (c) 2010 Arnau Sanchez
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

# Usage: $0 [OUTPUT_DIR] [QUEUE_FILE]
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
