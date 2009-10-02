#!/bin/bash
set -e

TESTSDIR=$(dirname "$(readlink -f "$0")")/test

# Support ArchLinux and Debian-like distros
PACKAGES="
kernel, uname -r -s
bash, bash --version, 4
sed, sed --version, NF
curl, curl --version, 2
recode, recode --version, 3
imagemagick, convert --version, 3
spidermonkey-js, js --version, 2
tesseract-ocr, which pacman &>/dev/null && { pacman -Q tesseract | awk '{print \$2}';  } || { dpkg -l tesseract-ocr | grep ^ii | awk '{print \$3}'; }
aview, aview --version, NF
"

basic_info() {
    VERSION=$(cat CHANGELOG | head -n1 | sed "s/^.*(\(.*\)).*$/\1/")
    REVISION=$(LC_ALL=C svn info  | grep ^Revision | cut -d: -f2 | xargs)
    echo "plowshare: $VERSION (r$REVISION)"
}

version_info() {
    while read LINE; do
        IFS="," read APP COMMAND FIELD <<< "$LINE"
        test "$APP" || continue
        if test "$FIELD"; then
            VERSION=$($COMMAND 2>&1 | head -n1 | awk "{print \$$FIELD}")
        else
            VERSION=$(bash -c "$COMMAND")
        fi
        echo "$APP: $VERSION"
    done <<< "$1"
}


basic_info
echo -e "\n--- Packages info"
version_info "$PACKAGES"
echo -e "\n--- Setup test"
$TESTSDIR/test_setup.sh
echo -e "\n--- Library tests"
$TESTSDIR/test_lib.sh
echo -e "\n--- Modules tests"
$TESTSDIR/test_modules.sh
