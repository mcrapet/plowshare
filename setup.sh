#!/bin/bash
#
# Install files in usual Linux paths
# Copyright (c) 2010 Arnau Sanchez
#
# This script is kept simple for portability purpose
# (`install' from GNU coreutils is not used here).
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

NAME=plowshare

# DESTDIR is provided for staged installs (used for packagers only)
DESTDIR=${DESTDIR:-}
PREFIX=${PREFIX:-/usr/local}

BINDIR="${DESTDIR}${PREFIX}/bin"
DATADIR="${DESTDIR}${PREFIX}/share/$NAME"
DOCDIR="${DESTDIR}${PREFIX}/share/doc/$NAME"
MANDIR="${DESTDIR}${PREFIX}/share/man/man1"

DATADIR_FINAL="${PREFIX}/share/$NAME"
MODULESDIR="$DATADIR/modules"
TESSERACTDIR="$DATADIR/tesseract"
USAGE="Usage: setup.sh install|uninstall"

CP='cp -v'
RM='rm -vf'
LN_S='ln -sf'

test $# -eq 0 && { echo "$USAGE"; exit 1; }
test -n "$DESTDIR" -a ! -d "$DESTDIR" && mkdir -p "$DESTDIR"
test -d "$PREFIX" || { echo "Error: bad prefix \`$PREFIX'"; exit 1; }

if [ "$1" = "uninstall" ]; then
    $RM -r $DATADIR $DOCDIR
    $RM $BINDIR/{plowdown,plowup,plowdel,plowlist}
    $RM $MANDIR/{plowdown,plowup,plowdel,plowlist}.1

elif [ "$1" = "install" ]; then
    # Documentation
    mkdir -p $DOCDIR $MANDIR
    $CP README $DOCDIR
    $CP docs/{plowdown,plowup,plowdel,plowlist}.1 $MANDIR

    # Common library
    mkdir -p $DATADIR
    $CP -p src/core.sh     \
        src/download.sh    \
        src/upload.sh      \
        src/delete.sh      \
        src/list.sh        \
        src/strip_single_color.pl \
        src/strip_threshold.pl $DATADIR

    # Modules
    mkdir -p $MODULESDIR
    $CP src/modules/*.sh src/moules/config $MODULESDIR

    # Tesseract
    mkdir -p $TESSERACTDIR
    $CP src/tesseract/* $TESSERACTDIR

    # Binary files
    mkdir -p $BINDIR
    $LN_S $DATADIR_FINAL/download.sh $BINDIR/plowdown
    $LN_S $DATADIR_FINAL/upload.sh $BINDIR/plowup
    $LN_S $DATADIR_FINAL/delete.sh $BINDIR/plowdel
    $LN_S $DATADIR_FINAL/list.sh $BINDIR/plowlist

else
    echo "$USAGE"
    exit 1
fi
