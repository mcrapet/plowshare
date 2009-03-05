#!/bin/bash
set -e

NAME=plowshare
DESTDIR=${DESTDIR:-}
USRDIR=${DESTDIR:-/usr/local}
LIBDIR=$USRDIR/share/$NAME
BINDIR=$USRDIR/bin
DOCSDIR=$USRDIR/share/doc/$NAME
MODULESDIR=$LIBDIR/modules
USAGE="Usage: setup.sh install|uninstall"

test $# -eq 0 && { echo "$USAGE"; exit 1; }

if [ "$1" = "uninstall" ]; then
    rm -vrf $LIBDIR $DOCSDIR
    rm -vf $BINDIR/{plowdown,plowup}
    exit 0
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
    cp -pv src/modules/extras/{jdownloader_captchas_db.gz,megaupload_captcha.py,*.ttf} \
        $MODULESDIR/extras
    chmod +x $MODULESDIR/extras/megaupload_captcha.py

    # Binary files
    mkdir -p $BINDIR 
    ln -vsf $(readlink -f $LIBDIR/download.sh) $BINDIR/plowdown
    ln -vsf $(readlink -f $LIBDIR/upload.sh) $BINDIR/plowup
else
    echo "$USAGE"
    exit 1
fi
