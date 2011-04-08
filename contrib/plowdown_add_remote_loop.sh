#!/bin/bash
#
# Script to add links to the queue on a server running plowdown_loop.sh (using SSH)
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

# Usage: $0 SERVER REMOTE_QUEUE_FILE LINK1 [LINK2] ...
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
