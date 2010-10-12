#!/bin/bash
#
# Automatic test for Plowshare toolset
# Copyright (c) 2010 Arnau Sanchez
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

set -e

ROOTDIR=$(dirname "$(readlink -f "$0")")
TESTSDIR="$ROOTDIR/test"

# Support ArchLinux and Debian-like distros
PACKAGES="
kernel, uname -r -s
bash, bash --version, 4
sed, sed --version, NF
curl, curl --version, 2
recode, recode --version, 3
imagemagick, convert --version, 3
spidermonkey-js, js --version, 2
tesseract-ocr, which pacman &>/dev/null && { pacman -Q tesseract | awk '{print \$2}';  } || { dpkg -l tesseract-ocr | grep ^ii | awk '{print \$3}'; }
aview, aview --version, NF
"

basic_info() {
    VERSION=$(cat "$ROOTDIR/CHANGELOG" | head -n1 | sed "s/^.*(\(.*\)).*$/\1/")
    if test -d '.svn'; then
        REVISION=$(LC_ALL=C svn info 2>/dev/null | grep ^Revision | cut -d' ' -f2)
    elif test -d '.git'; then
        REVISION=$(LC_ALL=C git svn info 2>/dev/null | grep ^Revision | cut -d' ' -f2)
    else
        REVISION=UNKNOWN
    fi
    echo "plowshare: $VERSION (r$REVISION)"
}

version_info() {
    while read LINE; do
        IFS="," read APP COMMAND FIELD <<< "$LINE"
        test "$APP" || continue
        if test "$FIELD"; then
            VERSION=$($COMMAND 2>&1 | head -n1 | awk "{print \$$FIELD}")
        else
            VERSION=$(bash -c "$COMMAND")
        fi
        echo "$APP: $VERSION"
    done <<< "$1"
}


#
# Main
#

if [ ! -d "$TESTSDIR" ]; then
  echo "Can't find test directory. This script must be called"
  echo "from root directory of Plowshare."
  exit 1
fi

basic_info
echo -e "\n--- Packages info"
version_info "$PACKAGES"
echo -e "\n--- Setup test"
$TESTSDIR/test_setup.sh
echo -e "\n--- Library tests"
$TESTSDIR/test_lib.sh
echo -e "\n--- Modules tests"
$TESTSDIR/test_modules.sh
