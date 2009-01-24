#!/bin/bash
set -e

NAME=plowshare
LIBDIR=/usr/local/share/$NAME
BINDIR=/usr/local/bin

mkdir -p $LIBDIR

# Binary files 
ln -sf $LIBDIR/download.sh $BINDIR/plowdown
ln -sf $LIBDIR/upload.sh $BINDIR/plowup

# Library 
cp main.sh download.sh upload.sh lib.sh $LIBDIR
cp megaupload.sh rapidshare.sh 2shared.sh $LIBDIR
