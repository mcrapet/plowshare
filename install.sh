#!/bin/bash
set -e

NAME=plowshare
MODULES="megaupload rapidshare 2shared"
LIBDIR=/usr/local/share/$NAME
BINDIR=/usr/local/bin

mkdir -p $LIBDIR

# Binary files 
ln -sf $LIBDIR/download.sh $BINDIR/plowdown
ln -sf $LIBDIR/upload.sh $BINDIR/plowup

# Common library 
cp main.sh download.sh upload.sh lib.sh $LIBDIR

# Modules
for MODULE in $MODULES; do
    cp module_$MODULE.sh $LIBDIR
done
