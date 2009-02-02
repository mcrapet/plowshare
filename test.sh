#!/bin/bash
set -e
SRCDIR=src/
source $SRCDIR/lib.sh

# Check that $1 is equal to $2.
assert_equal() {
  if ! test "$1" = "$2"; then
    echo "assert_equal failed: $1 != $2"
    return 1
  fi
}

# Check that regexp $1 matches $2.
assert_match() {
  if ! grep -q "$1" <<< "$2"; then
    echo "assert_match failed: regexp $1 does not match $2"
    return 1
  fi
}

# Check that $1 is not a empty string
assert() {
  if ! test "$1"; then
    echo "assert failed"
    return 1
  fi
}

# Run a test
run() {
  echo -n "$1... "
  "$@" && echo " ok" || echo " failed!"
}

download() {
    $SRCDIR/download.sh "$@" 2>/dev/null
}

upload() {
    $SRCDIR/upload.sh "$@" 2>/dev/null
}

UPFILE="/etc/services"

## Rapidshare

RAPIDSHARE_URL="http://www.rapidshare.com/files/86545320/Tux-Trainer_25-01-2008.rar"

test_rapidshare_download_anonymous() {
    assert_equal "Tux-Trainer_25-01-2008.rar" "$(download $RAPIDSHARE_URL)"
}        

test_rapidshare_upload_anonymous() {
    assert_match "http://rapidshare.com/files/" "$(upload rapidshare $UPFILE)"
}        

test_rapidshare_upload_freezone() {
    FREEZONE_URL="https://ssl.rapidshare.com/cgi-bin/collectorszone.cgi"
    AUTH=$(cat .rapidshare-auth)
    COOKIES=$(post_login "username" "password" "$AUTH" "$FREEZONE_URL" 2>/dev/null)
    PARSE="<td>Files: <b>\(.*\)<\/b>"
    FILES1=$(curl -s -b <(echo "$COOKIES") "$FREEZONE_URL" | parse $PARSE)
    URL=$(upload rapidshare -- -a "$AUTH" $UPFILE)
    assert_match "http://rapidshare.com/files/" "$URL" 
    FILES2=$(curl -s -b <(echo "$COOKIES") "$FREEZONE_URL" | parse $PARSE)
    assert_equal $(($FILES1+1)) $FILES2    
}        

## Megaupload

MEGAUPLOAD_URL="http://www.megaupload.com/?d=ieo1g52v"

test_megaupload_download_anonymous() {
    assert_equal "testmotion2.mp4" "$(download $MEGAUPLOAD_URL)"
}        

test_megaupload_download_member() {
    AUTH=$(cat .megaupload-auth)
    assert_equal "testmotion2.mp4" "$(download -a "$AUTH" $MEGAUPLOAD_URL)"
}        

test_megaupload_upload_anonymous() {
    URL="$(upload megaupload $UPFILE 'Plowshare test')"
    assert_match "http://www.megaupload.com/?d=" "$URL"
}        

test_megaupload_upload_member() {
    AUTH=$(cat .megaupload-auth)
    URL=$(upload megaupload -- -a "$AUTH" "$UPFILE" 'Plowshare test')
    assert_equal "http://www.megaupload.com/?d=IDXJG1RN" "$URL"
}        

## 2Shared

SHARED_URL="http://www.2shared.com/file/4446939/c9fd70d6/Test.html"

test_2shared_download() {
    assert_equal "Test.mp3" "$(download $SHARED_URL)"
}        

test_2shared_upload() {
    assert_match "^http://www.2shared.com/file/" "$(upload 2shared "$UPFILE")"
}        

### Main


TESTS=$(set | grep "^test_" | awk '$2 == "()"' | awk '{print $1}' | xargs)
test $# -eq 0 || TESTS="$@" 
for TEST in $TESTS; do
    run $TEST
done
