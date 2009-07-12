#!/bin/bash
set -e

# Note that *-auth files are not in the source code, you need to create
# them with your accounts if you want to run the function test suite.

ROOTDIR=$(dirname $(dirname "$(readlink -f "$0")"))
SRCDIR=$ROOTDIR/src
EXTRASDIR=$ROOTDIR/src/modules/extras
TESTSDIR=$ROOTDIR/test
source $ROOTDIR/src/lib.sh
source $ROOTDIR/test/lib.sh

### Setup script

INSTALLED="usr
usr/local
usr/local/bin
usr/local/bin/plowdown
usr/local/bin/plowup
usr/local/share
usr/local/share/doc
usr/local/share/doc/plowshare
usr/local/share/doc/plowshare/CHANGELOG
usr/local/share/doc/plowshare/COPYING
usr/local/share/doc/plowshare/README
usr/local/share/plowshare
usr/local/share/plowshare/download.sh
usr/local/share/plowshare/lib.sh
usr/local/share/plowshare/modules
usr/local/share/plowshare/modules/2shared.sh
usr/local/share/plowshare/modules/4shared.sh
usr/local/share/plowshare/modules/badongo.sh
usr/local/share/plowshare/modules/extras
usr/local/share/plowshare/modules/mediafire.sh
usr/local/share/plowshare/modules/megaupload.sh
usr/local/share/plowshare/modules/rapidshare.sh
usr/local/share/plowshare/modules/zshare.sh
usr/local/share/plowshare/upload.sh"

UNINSTALLED="usr
usr/local
usr/local/bin
usr/local/share
usr/local/share/doc"

test_setup_script() {
    TEMPDIR=$(mktemp -d)
    assert_return 0 "DESTDIR=$TEMPDIR $ROOTDIR/setup.sh install"
    assert_equal "$INSTALLED" \
        "$(find $TEMPDIR | sed "s#^$TEMPDIR/\?##" | grep -v "^$" | sort)"
    assert_return 0 "DESTDIR=$TEMPDIR $ROOTDIR/setup.sh uninstall"
    assert_equal "$UNINSTALLED" \
        "$(find $TEMPDIR | sed "s#^$TEMPDIR/\?##" | grep -v "^$" | sort)"
    rm -rf $TEMPDIR
}

run_tests "$@"
