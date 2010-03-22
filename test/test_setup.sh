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
# Note that *-auth files are not in the source code, you need to create
# them with your accounts if you want to run the function test suite.

set -e

ROOTDIR=$(dirname $(dirname "$(readlink -f "$0")"))
SRCDIR=$ROOTDIR/src
TESTSDIR=$ROOTDIR/test
source $ROOTDIR/src/lib.sh
source $ROOTDIR/test/lib.sh

### Setup script

PREFIX=/usr
EXPECTED_INSTALLED="bin
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
share/plowshare/examples
share/plowshare/examples/plowdown_add_remote_loop.sh
share/plowshare/examples/plowdown_loop.sh
share/plowshare/examples/plowdown_parallel.sh
share/plowshare/lib.sh
share/plowshare/list.sh
share/plowshare/modules
share/plowshare/modules/2shared.sh
share/plowshare/modules/4shared.sh
share/plowshare/modules/badongo.sh
share/plowshare/modules/data_hu.sh
share/plowshare/modules/depositfiles.sh
share/plowshare/modules/divshare.sh
share/plowshare/modules/dl_free_fr.sh
share/plowshare/modules/filefactory.sh
share/plowshare/modules/hotfile.sh
share/plowshare/modules/humyo.sh
share/plowshare/modules/letitbit.sh
share/plowshare/modules/mediafire.sh
share/plowshare/modules/megaupload.sh
share/plowshare/modules/netload_in.sh
share/plowshare/modules/rapidshare.sh
share/plowshare/modules/sendspace.sh
share/plowshare/modules/storage_to.sh
share/plowshare/modules/uploaded_to.sh
share/plowshare/modules/uploading.sh
share/plowshare/modules/usershare.sh
share/plowshare/modules/x7_to.sh
share/plowshare/modules/zshare.sh
share/plowshare/strip_grey.pl
share/plowshare/strip_single_color.pl
share/plowshare/tesseract
share/plowshare/tesseract/digit
share/plowshare/tesseract/digit_ops
share/plowshare/tesseract/plowshare_nobatch
share/plowshare/tesseract/upper
share/plowshare/upload.sh"

EXPECTED_UNINSTALLED="bin
share
share/doc"

test_setup_script() {
    TEMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/plowshare.XXXXXXXX")

    assert_return 0 "PREFIX=$PREFIX DESTDIR=$TEMPDIR $ROOTDIR/setup.sh install" || return 1
    INSTALLED=$(find "$TEMPDIR$PREFIX" | sed "s#^$TEMPDIR$PREFIX/\?##" | sed '/^$/d' | sort)
    diff -i <(echo "$EXPECTED_INSTALLED") <(echo "$INSTALLED")
    assert_equal "$EXPECTED_INSTALLED" \
        "$INSTALLED" || return 1
    assert_return 0 "PREFIX=$PREFIX DESTDIR=$TEMPDIR $ROOTDIR/setup.sh uninstall" || return 1
    assert_equal "$EXPECTED_UNINSTALLED" \
        "$(find "$TEMPDIR$PREFIX" | sed "s#^$TEMPDIR$PREFIX/\?##" | sed '/^$/d' | sort)" || return 1

    rm -rf $TEMPDIR
}

run_tests "$@"
