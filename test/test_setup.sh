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

INSTALLED="bin
bin/plowdel
bin/plowdown
bin/plowup
share
share/doc
share/doc/plowshare
share/doc/plowshare/CHANGELOG
share/doc/plowshare/README
share/plowshare
share/plowshare/delete.sh
share/plowshare/download.sh
share/plowshare/lib.sh
share/plowshare/modules
share/plowshare/modules/2shared.sh
share/plowshare/modules/4shared.sh
share/plowshare/modules/badongo.sh
share/plowshare/modules/depositfiles.sh
share/plowshare/modules/letitbit.sh
share/plowshare/modules/mediafire.sh
share/plowshare/modules/megaupload.sh
share/plowshare/modules/rapidshare.sh
share/plowshare/modules/uploaded_to.sh
share/plowshare/modules/zshare.sh
share/plowshare/upload.sh"

UNINSTALLED="bin
share
share/doc"

test_setup_script() {
    TEMPDIR=$(mktemp -d)
    assert_return 0 "DESTDIR=$TEMPDIR $ROOTDIR/setup.sh install" || return 1
    assert_equal "$INSTALLED" \
        "$(find $TEMPDIR | sed "s#^$TEMPDIR/\?##" | grep -v "^$" | sort)" || return 1
    assert_return 0 "DESTDIR=$TEMPDIR $ROOTDIR/setup.sh uninstall" || return 1
    assert_equal "$UNINSTALLED" \
        "$(find $TEMPDIR | sed "s#^$TEMPDIR/\?##" | grep -v "^$" | sort)" || return 1
    rm -rf $TEMPDIR
}

run_tests "$@"
