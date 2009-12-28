#!/bin/bash
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
#
set -e

NAME=plowshare
DESTDIR=${DESTDIR:-/usr/local}
USRDIR=$DESTDIR
LIBDIR=$USRDIR/share/$NAME
BINDIR=$USRDIR/bin
DOCSDIR=$USRDIR/share/doc/$NAME
MODULESDIR=$LIBDIR/modules
USAGE="Usage: setup.sh install|uninstall"

CP='cp -v'
RM='rm -vf'
LN_S='ln -vsf'

test $# -eq 0 && { echo "$USAGE"; exit 1; }

if [ "$1" = "uninstall" ]; then
    $RM -r $LIBDIR $DOCSDIR
    $RM $BINDIR/{plowdown,plowup,plowdel}

elif [ "$1" = "install" ]; then
    # Documentation
    mkdir -p $DOCSDIR
    $CP CHANGELOG README $DOCSDIR

    # Common library
    mkdir -p $LIBDIR
    $CP -p src/download.sh \
        src/upload.sh   \
        src/delete.sh   \
        src/lib.sh      \
        src/strip_single_color.pl $LIBDIR

    # Modules
    mkdir -p $MODULESDIR
    $CP src/modules/*.sh $MODULESDIR

    # Binary files
    mkdir -p $BINDIR
    $LN_S $LIBDIR/download.sh $BINDIR/plowdown
    $LN_S $LIBDIR/upload.sh $BINDIR/plowup
    $LN_S $LIBDIR/delete.sh $BINDIR/plowdel

else
    echo "$USAGE"
    exit 1
fi
