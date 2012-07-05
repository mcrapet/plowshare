#!/bin/sh
#
# Install files in usual Linux paths
# Copyright (c) 2010 Arnau Sanchez
# Copyright (c) 2011-2012 Plowshare team
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
MANDIR1="${DESTDIR}${PREFIX}/share/man/man1"
MANDIR5="${DESTDIR}${PREFIX}/share/man/man5"

DATADIR_FINAL="${PREFIX}/share/$NAME"
MODULESDIR="$DATADIR/modules"
USAGE='Usage: setup.sh install|uninstall'

CP='cp -v'
RM='rm -vf'
LN_S='ln -sf'

if [ $# -ne 1 ]; then
    echo "$USAGE"
    exit 1
fi

if test -n "$DESTDIR"; then
    if ! test -d "$DESTDIR"; then
        mkdir -p "$DESTDIR"
    fi
elif ! test -d "$PREFIX"; then
    echo "Error: bad prefix \`$PREFIX' (directory does not exist)"
    exit 1
fi

if [ "$1" = 'uninstall' ]; then
    $RM -r "$DATADIR" "$DOCDIR"
    $RM "$BINDIR/plowdown" "$BINDIR/plowup" "$BINDIR/plowdel" "$BINDIR/plowlist"
    $RM "$MANDIR1/plowdown.1" "$MANDIR1/plowup.1" "$MANDIR1/plowdel.1" "$MANDIR1/plowlist.1" "$MANDIR5/plowshare.conf.5"

elif [ "$1" = 'install' ]; then
    # Documentation
    mkdir -p "$DOCDIR" "$MANDIR1" "$MANDIR5"
    $CP AUTHORS README "$DOCDIR"
    $CP docs/plowdown.1 docs/plowup.1 docs/plowdel.1 docs/plowlist.1 "$MANDIR1"
    $CP docs/plowshare.conf.5 "$MANDIR5"

    # Common library
    mkdir -p "$DATADIR"
    $CP -p src/core.sh     \
        src/download.sh    \
        src/upload.sh      \
        src/delete.sh      \
        src/list.sh        \
        "$DATADIR"

    # Modules
    mkdir -p "$MODULESDIR"
    $CP src/modules/*.sh src/modules/config "$MODULESDIR"

    # Binary files
    mkdir -p "$BINDIR"
    $LN_S "$DATADIR_FINAL/download.sh" "$BINDIR/plowdown"
    $LN_S "$DATADIR_FINAL/upload.sh" "$BINDIR/plowup"
    $LN_S "$DATADIR_FINAL/delete.sh" "$BINDIR/plowdel"
    $LN_S "$DATADIR_FINAL/list.sh" "$BINDIR/plowlist"

    # Check sed version (don't use `uname -s` yet..)
    SED=`sed --version 2>&1 | sed 1q` || true
    case $SED in
        # GNU sed version 4.2.1
        GNU\ sed*)
            ;;
        # BSD, Busybox (old versions):
        # sed: illegal option -- -
        # This is not GNU sed version 4.0
        *)
            echo "Warning: sytem sed is not GNU sed"
            for SED_PRG in gsed gnu-sed; do
                SED_PATH=`command -v $SED_PRG 2>/dev/null` || true
                if [ -n "$SED_PATH" ]; then
                    echo "Patching core.sh to call $SED_PRG"
                    sed -i -e '/^set -/a\
'"shopt -s expand_aliases; alias sed='$SED_PRG'" "$DATADIR/core.sh"
                    break
                fi
            done
            ;;
    esac
else
    echo "$USAGE"
    exit 1
fi
