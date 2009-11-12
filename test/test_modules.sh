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

download() {
    $SRCDIR/download.sh "$@" 2>/dev/null
}

download_with_debug() {
    $SRCDIR/download.sh "$@"
}

upload() {
    $SRCDIR/upload.sh "$@" 2>/dev/null
}

delete() {
    $SRCDIR/delete.sh "$@" 2>/dev/null
}


UPFILE="$ROOTDIR/COPYING"
UPFILE2="$ROOTDIR/CHANGELOG"

## Rapidshare

RAPIDSHARE_URL="http://www.rapidshare.com/files/86545320/Tux-Trainer_25-01-2008.rar"

test_rapidshare_download_anonymous() {
    FILENAME="Tux-Trainer_25-01-2008.rar"
    assert_equal "$FILENAME" "$(download $RAPIDSHARE_URL)" || return 1
    rm -f $FILENAME
}        

test_rapidshare_upload_anonymous() {
    assert_match "http://rapidshare.com/files/" "$(upload $UPFILE rapidshare)" ||
        return 1
}        

test_rapidshare_upload_freezone() {
    FREEZONE_URL="https://ssl.rapidshare.com/cgi-bin/collectorszone.cgi"
    test -e $TESTSDIR/.rapidshare-auth || return 255
    AUTH=$(cat $TESTSDIR/.rapidshare-auth)
    LOGIN_DATA='username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH" "$LOGIN_DATA" "$FREEZONE_URL" 2>/dev/null)
    PARSE="<td>Files: <b>\(.*\)<\/b>"
    FILES1=$(curl -s -b <(echo "$COOKIES") "$FREEZONE_URL" | parse $PARSE)
    URL=$(upload -a "$AUTH" $UPFILE rapidshare)
    assert_match "http://rapidshare.com/files/" "$URL" || return 1 
    FILES2=$(curl -s -b <(echo "$COOKIES") "$FREEZONE_URL" | parse $PARSE)
    assert_equal $(($FILES1+1)) $FILES2 || return 1
}        

test_rapidshare_check_active_link() {
    assert_equal "$RAPIDSHARE_URL" "$(download -c $RAPIDSHARE_URL)" || return 1
}                

## Megaupload

MEGAUPLOAD_URL="http://www.megaupload.com/?d=ieo1g52v"

test_megaupload_download_anonymous() {
    FILENAME="testmotion2.mp4"
    assert_equal "$FILENAME" "$(download $MEGAUPLOAD_URL)" || return 1
    rm -f $FILENAME
}        

test_megaupload_download_a_password_protected_file() {
    URL="http://www.megaupload.com/?d=4YF0D6A3"
    FILENAME="asound.conf"
    assert_equal "$FILENAME" "$(download -p test1 $URL)" || return 1
    rm -f $FILENAME
}

test_megaupload_download_a_password_protected_file_with_premium_account() {
    URL="http://www.megaupload.com/?d=4YF0D6A3"
    FILENAME="asound.conf"
    assert_equal "$FILENAME" "$(download -a "$AUTH" -p test1 $URL)" || return 1
    rm -f $FILENAME
}

test_megaupload_download_member() {
    test -e $TESTSDIR/.megaupload-auth || return 255
    AUTH=$(cat $TESTSDIR/.megaupload-auth)
    OUTPUT=$(download_with_debug -a "$AUTH" $MEGAUPLOAD_URL 2>&1)
    assert_match "^Waiting 26 seconds" "$OUTPUT" || return 1
    URL=$(echo "$OUTPUT" | tail -n1)
    FILENAME="testmotion2.mp4"
    assert_equal "$FILENAME" "$URL" || return 1
    rm -f $FILENAME
}        

test_megaupload_download_premium() {
    test -e $TESTSDIR/.megaupload-premium-auth || return 255
    AUTH=$(cat $TESTSDIR/.megaupload-premium-auth)
    OUTPUT=$(download -a "$AUTH" $MEGAUPLOAD_URL)
    FILENAME="testmotion2.mp4"
    assert_equal "$FILENAME" "$OUTPUT" || return 1 
    rm -f $FILENAME
}

test_megaupload_check_active_link() {
    assert_equal "$MEGAUPLOAD_URL" "$(download -c $MEGAUPLOAD_URL)" || return 1
}                

test_megaupload_upload_anonymous() {
    URL="$(upload -d 'Plowshare test' $UPFILE megaupload)"
    assert_match "http://www.megaupload.com/?d=" "$URL" || return 1
}        

test_megaupload_upload_member() {
    test -e $TESTSDIR/.megaupload-auth || return 255
    AUTH=$(cat $TESTSDIR/.megaupload-auth)
    URL=$(upload -d 'Plowshare test' -a "$AUTH" $UPFILE megaupload)
    assert_match "http://www.megaupload.com/?d=" "$URL" || return 1
}        

test_megaupload_upload_premium_with_password() {
    test -e $TESTSDIR/.megaupload-premium-auth || return 255
    AUTH=$(cat $TESTSDIR/.megaupload-premium-auth)
    URL=$(upload -a "$AUTH" -p "mypassword" \
        -d 'Plowshare test' $UPFILE megaupload)
    assert_match "http://www.megaupload.com/?d=" "$URL" || return 1
    assert_return 0 'match "name=\"filepassword\"" "$(curl $URL)"' || return 1
}        

test_megaupload_upload_premium_using_multifetch() {
    test -e $TESTSDIR/.megaupload-premium-auth || return 255
    AUTH=$(cat $TESTSDIR/.megaupload-premium-auth)
    URL=$(upload -a "$AUTH" --multifetch --clear-log \
        -d 'Plowshare test' "http://www.gnu.org/licenses/gpl.txt" megaupload)
    assert_match "http://www.megaupload.com/?d=" "$URL" || return 1
}        

test_megaupload_delete_member() {
    test -e $TESTSDIR/.megaupload-auth || return 255
    AUTH=$(cat $TESTSDIR/.megaupload-auth)
    URL=$(upload -d 'Plowshare test' -a "$AUTH" $UPFILE2 megaupload)
    assert_return 0 "delete -a $AUTH $URL" || return 1
}        

## 2Shared

SHARED_URL="http://www.2shared.com/file/4446939/c9fd70d6/Test.html"

test_2shared_download() {
    FILENAME="Test.mp3"
    assert_equal "$FILENAME" "$(download $SHARED_URL)" || return 1
    rm -f $FILENAME
}        

test_2shared_download_and_get_only_link() {
    URL="2shared.com/download/4446939/c9fd70d6/Test.mp3"
    assert_match "$URL" "$(download -l $SHARED_URL)" || return 1    
}

test_2shared_download_using_file_argument_and_mark_as_downloaded() {
    URL="2shared.com/download/4446939/c9fd70d6/Test.mp3"
    TEMP=$(create_tempfile)
    echo "$SHARED_URL" > $TEMP
    assert_match "$URL" "$(download -l -m "$TEMP")" || return 1
    assert_match "^#$SHARED_URL" "$(cat $TEMP)" || return 1
    rm -f "$TEMP"    
}        

test_2shared_check_active_link() {
    assert_equal "$SHARED_URL" "$(download -c $SHARED_URL)" || return 1
}                
        
test_2shared_upload() {
    assert_match "^http://www.2shared.com/file/" "$(upload $UPFILE 2shared)" ||
        return 1
}        

## Badongo

BADONGO_URL="http://www.badongo.com/file/13153017"

test_badongo_download() {
    FILENAME="Kandinsky_Wassily_-_De_lo_espiritual_en_el_arte.rar"
    assert_equal "$FILENAME" "$(download $BADONGO_URL)" || return 1
    rm -f $FILENAME
}        

test_badongo_check_active_link() {
    assert_equal "$BADONGO_URL" "$(download -c $BADONGO_URL)" || return 1
}                

## Mediafire

MEDIAFIRE_URL="http://www.mediafire.com/?mokvnz2y43y"

test_mediafire_download() {
    FILENAME="Nature+Medicine.pdf"
    assert_equal "$FILENAME" "$(download $MEDIAFIRE_URL)" || return 1
    rm -f $FILENAME
}        

test_mediafire_check_active_link() {
    assert_equal "$MEDIAFIRE_URL" "$(download -c $MEDIAFIRE_URL)" || return 1
}                

## 4shared

FSHARED_URL="http://www.4shared.com/file/14767114/7939c436/John_Milton_-_Paradise_Lost.html?s=1"

test_4shared_download() {
    FILENAME="John_Milton_-_Paradise_Lost.pdf"
    assert_equal "$FILENAME" "$(download $FSHARED_URL)" || return 1
    rm -f $FILENAME
}        

test_4shared_check_active_link() {
    assert_equal "$FSHARED_URL" "$(download -c $FSHARED_URL)" || return 1
}        

# Zshare

ZSHARE_URL="http://www.zshare.net/download/5065479160b3f7b2/"

test_zshare_download() {
    FILENAME="swos_fullrip_killer_pepo_absba.part01.rar"
    assert_match "/$FILENAME$" "$(download -l $ZSHARE_URL)" || return 1
    rm -f $FILENAME
}        

test_zshare_check_active_link() {
    assert_equal "$ZSHARE_URL" "$(download -c $ZSHARE_URL)" || return 1
}        

# Depositfiles

DEPOSIT_SMALL_URL="http://depositfiles.com/es/files/sswznjsu2"
DEPOSIT_BIG_URL="http://depositfiles.com/es/files/vd58vei0y"

test_depositfiles_check_active_link() {
    assert_equal "$DEPOSIT_SMALL_URL" "$(download -c $DEPOSIT_SMALL_URL)" || return 1
    assert_equal "" "$(download -c ${DEPOSIT_SMALL_URL}wronglink)" || return 1
}        

test_depositfiles_download_small_file() {
    FILENAME="untitled87.bmp"
    assert_equal "$FILENAME" "$(download $DEPOSIT_SMALL_URL)" || return 1
    rm -f $FILENAME
}        

test_depositfiles_download_big_file() {
    FILENAME="1002-BIOS-Asus_P5Q_SE_for_MAC_OS_X___VISTA_SLIC_all_OS__incl._by_Juzzi..ROM.zip"
    assert_equal "$FILENAME" "$(download $DEPOSIT_BIG_URL)" || return 1
    rm -f $FILENAME
}        


run_tests "$@"
