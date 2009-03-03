#!/bin/bash
set -e

NAME=plowshare
INSTALLDIR=${INSTALLDIR:-/usr/local}
LIBDIR=$INSTALLDIR/share/$NAME
BINDIR=$INSTALLDIR/bin
DOCSDIR=$INSTALLDIR/share/doc/$NAME
MODULESDIR=$LIBDIR/modules

# Uninstall
if [ "$1" = "uninstall" ]; then
    rm -vrf $LIBDIR $DOCSDIR
    rm -vf $BINDIR/{plowdown,plowup}
    exit 0
fi

# Documentation
mkdir -p $DOCSDIR
cp -v CHANGELOG COPYING README $DOCSDIR 

# Enter to source directory
cd src

# Common library 
mkdir -p $LIBDIR
cp -pv download.sh upload.sh lib.sh $LIBDIR

# Modules
mkdir -p $MODULESDIR
cp -v modules/*.sh $MODULESDIR
mkdir -p $MODULESDIR/extras
cp -pv modules/extras/{jdownloader_captchas_db.gz,megaupload_captcha.py,*.ttf} \
    $MODULESDIR/extras
chmod +x $MODULESDIR/extras/megaupload_captcha.py

# Binary files
mkdir -p $BINDIR 
ln -vsf $(readlink -f $LIBDIR/download.sh) $BINDIR/plowdown
ln -vsf $(readlink -f $LIBDIR/upload.sh) $BINDIR/plowup
