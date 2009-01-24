#!/bin/bash
set -e

NAME=plowshare
MODULES="megaupload rapidshare 2shared"
INSTALLDIR=/usr/local
LIBDIR=$INSTALLDIR/share/$NAME
BINDIR=$INSTALLDIR/bin

mkdir -p $LIBDIR

# Common library 
cp main.sh download.sh upload.sh lib.sh $LIBDIR

# Modules
for MODULE in $MODULES; do
    cp module_$MODULE.sh $LIBDIR
done

# Binary files 
ln -sf $LIBDIR/download.sh $BINDIR/plowdown
ln -sf $LIBDIR/upload.sh $BINDIR/plowup
