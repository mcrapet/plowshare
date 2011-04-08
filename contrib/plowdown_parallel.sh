#!/bin/bash
#
# Launch parallel plowdown processes for different websites
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

# Usage: $0 FILE_WITH_ONE_LINK_PER_LINE [PLOWDOWN_OPTIONS]
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
