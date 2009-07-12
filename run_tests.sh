#!/bin/bash
set -e

TESTSDIR=$(dirname "$(readlink -f "$0")")/test
PACKAGES="
kernel, uname -r -s
bash, --version, 4
sed, --version, NF
curl, --version, 2
recode, --version, 3
convert, --version, 3
smjs, --version, 2
tesseract, pacman -Q tesseract | awk '{print \$2}'
python, --version, 2
python-imaging, python -c 'import PIL.Image as i; print i.VERSION'
aview, --version, 5
"

basic_info() {
    VERSION=$(cat CHANGELOG | head -n1 | sed "s/^.*(\(.*\)).*$/\1/")
    echo "plowshare: $VERSION"
}

version_info() {
    while read LINE; do
        IFS="," read APP ARGS FIELD <<< "$LINE"
        test "$APP" || continue
        if test "$FIELD"; then
            VERSION=$($APP $ARGS 2>&1 | head -n1 | awk "{print \$$FIELD}")
        else
            VERSION=$(bash -c "$ARGS")
        fi
        echo "$APP: $VERSION"
    done <<< "$1"
}


basic_info
echo
echo "--- Packages info"
version_info "$PACKAGES"
echo
echo "--- Setup test"
$TESTSDIR/test_setup.sh
echo
echo "--- Library tests"
$TESTSDIR/test_lib.sh
echo 
echo "--- Modules tests"
$TESTSDIR/test_modules.sh
