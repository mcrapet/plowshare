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
DESTDIR=${DESTDIR:-}
USRDIR=$DESTDIR/usr/local
LIBDIR=$USRDIR/share/$NAME
BINDIR=$USRDIR/bin
DOCSDIR=$USRDIR/share/doc/$NAME
MODULESDIR=$LIBDIR/modules
BIN2LIB=../share/$NAME
USAGE="Usage: setup.sh install|uninstall"

test $# -eq 0 && { echo "$USAGE"; exit 1; }

if [ "$1" = "uninstall" ]; then
    rm -vrf $LIBDIR $DOCSDIR
    rm -vf $BINDIR/{plowdown,plowup}

elif [ "$1" = "install" ]; then
    # Documentation
    mkdir -p $DOCSDIR
    cp -v CHANGELOG COPYING README $DOCSDIR 

    # Common library 
    mkdir -p $LIBDIR
    cp -pv src/download.sh src/upload.sh src/lib.sh $LIBDIR

    # Modules
    mkdir -p $MODULESDIR
    cp -v src/modules/*.sh $MODULESDIR
    mkdir -p $MODULESDIR/extras

    # Binary files
    mkdir -p $BINDIR 
    ln -vsf $BIN2LIB/download.sh $BINDIR/plowdown
    ln -vsf $BIN2LIB/upload.sh $BINDIR/plowup
    ln -vsf $BIN2LIB/delete.sh $BINDIR/plowdelete

else
    echo "$USAGE"
    exit 1
fi
