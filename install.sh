#!/bin/bash
set -e

NAME=plowshare
MODULES="megaupload rapidshare 2shared"
INSTALLDIR=${1:-/usr/local}
LIBDIR=$INSTALLDIR/share/$NAME
BINDIR=$INSTALLDIR/bin
DOCSDIR=$INSTALLDIR/share/doc/$NAME
MODULESDIR=$LIBDIR/modules

# Documentation
mkdir -p $DOCSDIR
cp -v CHANGELOG COPYING README $DOCSDIR 

# Enter to source directory
cd src

# Common library 
mkdir -p $LIBDIR
cp -v main.sh download.sh upload.sh lib.sh $LIBDIR

# Modules
mkdir -p $MODULESDIR
for MODULE in $MODULES; do
    cp -v modules/$MODULE.sh $MODULESDIR
done

# Binary files
mkdir -p $BINDIR 
ln -vsf $(readlink -f $LIBDIR/download.sh) $BINDIR/plowdown
ln -vsf $(readlink -f $LIBDIR/upload.sh) $BINDIR/plowup
