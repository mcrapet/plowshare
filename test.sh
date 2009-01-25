#!/bin/bash
set -e

SRCDIR=src/

# Check that $1 is equal to $2.
assert_equal() {
  if ! test "$1" = "$2"; then
    echo "assert_equal failed: $1 != $2"
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
# $1..N: Function to run
run() {
  echo -n "$1... "
  "$@" && echo " ok" || echo " failed!"
}

### Tests
 
download() {
    $SRCDIR/download.sh "$@" 2>/dev/null
}

upload() {
    $SRCDIR/upload.sh "$@" 2>/dev/null
}

### Tests

RAPIDSHARE_URL="http://www.rapidshare.com/files/86545320/Tux-Trainer_25-01-2008.rar"
MEGAUPLOAD_URL="http://www.megaupload.com/?d=ieo1g52v"
SHARED_URL="http://www.2shared.com/file/4446939/c9fd70d6/Test.html"

test_rapidshare_download_anonymous() {
    assert_equal "Tux-Trainer_25-01-2008.rar" "$(download $RAPIDSHARE_URL)"
}        

test_megaupload_download_anonymous() {
    assert_equal "testmotion2.mp4" "$(download $MEGAUPLOAD_URL)"
}        

test_megaupload_download_member() {
    AUTH=$(cat .megaupload.auth)
    assert_equal "testmotion2.mp4" "$(download -a "$AUTH" $MEGAUPLOAD_URL)"
}        

test_megaupload_upload_anonymous() {
    URL="$(upload megaupload <(echo '1234') 'Plowshare test')"
    assert "$(echo $URL | grep -o 'http://www.megaupload.com/?d=')" 
}        

test_megaupload_upload_member() {
    AUTH=$(cat .megaupload.auth)
    URL=$(upload -a "$AUTH" megaupload <(echo '1234') 'Plowshare test')
    assert_equal "http://www.megaupload.com/?d=RT1N8HKM" "$URL"
}        

test_2shared_download_anonymous() {
    assert_equal "Test.mp3" "$(download $SHARED_URL)"
}        


# Rapidshare
run "test_rapidshare_download_anonymous"

# Megaupload
run "test_megaupload_download_anonymous"
run "test_megaupload_download_member"
run "test_megaupload_upload_anonymous"
run "test_megaupload_upload_member"

# 2Shared
run "test_2shared_download_anonymous"
