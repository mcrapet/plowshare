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

source "$SRCDIR/lib.sh"
source "$TESTSDIR/lib.sh"

# No debug messages (-q)
download() {
    $SRCDIR/download.sh -q "$@"
}

upload() {
    $SRCDIR/upload.sh "$@" 2>/dev/null
}

delete() {
    $SRCDIR/delete.sh "$@" 2>/dev/null
}


UPFILE="$ROOTDIR/COPYING"
UPFILE2="$ROOTDIR/CHANGELOG"

# Rapidshare

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

# Megaupload

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
    FILENAME="testmotion2.mp4"
    assert_equal "$FILENAME" "$(download -a "$AUTH" $MEGAUPLOAD_URL)" || return 1
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

# 2Shared.com

SHARED_URL="http://www.2shared.com/file/4446939/c9fd70d6/Test.html"

test_2shared_download() {
    FILENAME="Test.mp3"
    assert_equal "$FILENAME" "$(download $SHARED_URL)" || return 1
    rm -f $FILENAME
}

test_2shared_download_and_get_only_link() {
    URL="2shared.com/download/4446939/c9fd70d6/Test.mp3"
    assert_match "http://.*Test.mp3.*" "$(download --run-download='echo %url' $SHARED_URL)" || return 1
}

test_2shared_download_using_file_argument_and_mark_as_downloaded() {
    URL="2shared.com/download/4446939/c9fd70d6/Test.mp3"
    TEMP=$(create_tempfile)
    echo "$SHARED_URL" > $TEMP
    assert_match "Test.mp3" $(download -m "$TEMP") || return 1
    assert_match "^# $SHARED_URL" "$(cat $TEMP)" || return 1
    rm -f "$TEMP"
}

test_2shared_check_active_link() {
    assert_equal "$SHARED_URL" "$(download -c $SHARED_URL)" || return 1
}

test_2shared_upload() {
    assert_match "^http://www.2shared.com/file/" "$(upload $UPFILE 2shared)" ||
        return 1
}

# Badongo.com

BADONGO_URL="http://www.badongo.com/file/10855869"

test_badongo_download() {
    FILENAME="0906_web_abstract.pdf"
    assert_equal "$FILENAME" "$(download $BADONGO_URL)" || return 1
    rm -f $FILENAME
}

test_badongo_check_active_link() {
    assert_equal "$BADONGO_URL" "$(download -c $BADONGO_URL)" || return 1
}

# Mediafire

MEDIAFIRE_URL="http://www.mediafire.com/?mokvnz2y43y"

test_mediafire_download() {
    FILENAME="Nature+Medicine.pdf"
    assert_equal "$FILENAME" "$(download $MEDIAFIRE_URL)" || return 1
    rm -f $FILENAME
}

test_mediafire_check_active_link() {
    assert_equal "$MEDIAFIRE_URL" "$(download -c $MEDIAFIRE_URL)" || return 1
}

# 4shared.com

FSHARED_URL="http://www.4shared.com/file/14767114/7939c436/John_Milton_-_Paradise_Lost.html?s=1"

test_4shared_download() {
    FILENAME="John_Milton_-_Paradise_Lost.pdf"
    assert_equal "$FILENAME" "$(download $FSHARED_URL)" || return 1
    rm -f $FILENAME
}

test_4shared_check_active_link() {
    assert_equal "$FSHARED_URL" "$(download -c $FSHARED_URL)" || return 1
}

# Zshare.net

ZSHARE_URL="http://www.zshare.net/download/70515576910ce6fa/"

test_zshare_download() {
    FILENAME="Malayalam_calendar_2010.pdf"
    assert_equal "$FILENAME" "$(download $ZSHARE_URL)" || return 1
    rm -f $FILENAME
}

test_zshare_check_active_link() {
    assert_equal "$ZSHARE_URL" "$(download -c $ZSHARE_URL)" || return 1
}

# Depositfiles.com

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

# Storage.to

STORAGE_TO_URL="http://www.storage.to/get/AMvFJROk/debian032.jpg"

test_storage_to_download() {
    FILENAME="debian032.jpg"
    assert_equal "$FILENAME" "$(download $STORAGE_TO_URL)" || return 1
    rm -f $FILENAME
}

test_storage_to_check_active_link() {
    assert_equal "$STORAGE_TO_URL" "$(download -c $STORAGE_TO_URL)" || return 1
}

# Uploaded.to

UPLOADED_TO_URL1="http://ul.to/t6h61d"
UPLOADED_TO_URL2="http://uploaded.to/file/t6h61d"

test_uploaded_to_download_short_url() {
    FILENAME="debian047.jpg"
    assert_equal "$FILENAME" "$(download $UPLOADED_TO_URL1)" || return 1
    rm -f $FILENAME
}

test_uploaded_to_download_long_url() {
    FILENAME="debian047.jpg"
    assert_equal "$FILENAME" "$(download $UPLOADED_TO_URL2)" || return 1
    rm -f $FILENAME
}

test_uploaded_to_check_active_link() {
    assert_equal "$UPLOADED_TO_URL1" "$(download -c $UPLOADED_TO_URL1)" || return 1
}

# Netload.in

NETLOAD_IN_URL="http://netload.in/dateiwDu3f8HcwV/RFCs0001-0500.tar.gz.htm"

test_netload_in_download() {
    FILENAME="RFCs0001-0500.tar.gz"
    assert_equal "$FILENAME" "$(download $NETLOAD_IN_URL)" || return 1
    rm -f $FILENAME
}

test_netload_in_check_active_link() {
    assert_equal "$NETLOAD_IN_URL" "$(download -c $NETLOAD_IN_URL)" || return 1
}

# Uploading.com

UPLOADING_URL="http://uploading.com/files/UQG58JMR/exkluderingar.xls.html"

test_uploading_download() {
    FILENAME="exkluderingar.xls"
    assert_equal "$FILENAME" "$(download $UPLOADING_URL)" || return 1
    rm -f $FILENAME
}

# Usershare.net

USERSHARE_URL="http://usershare.net/w9ylfullshau"

test_usershare_download() {
    FILENAME="Test.mp3"
    assert_equal "$FILENAME" "$(download $USERSHARE_URL)" || return 1
    rm -f $FILENAME
}

test_usershare_check_active_link() {
    assert_equal "$USERSHARE_URL" "$(download -c $USERSHARE_URL)" || return 1
}

# Sendspace.net

SENDSPACE_URL="http://www.sendspace.com/file/sjw4sk"

test_sendspace_download() {
    FILENAME="Test.mp3"
    assert_equal "$FILENAME" "$(download $SENDSPACE_URL)" || return 1
    rm -f $FILENAME
}

test_sendspace_check_active_link() {
    assert_equal "$SENDSPACE_URL" "$(download -c $SENDSPACE_URL)" || return 1
}

# x7.to

X7_TO_URL="http://x7.to/gns6cw"

test_x7_to_download() {
    FILENAME="pdfrfc0001-0500.zip"
    assert_equal "$FILENAME" "$(download $X7_TO_URL)" || return 1
    rm -f $FILENAME
}

test_x7_to_check_active_link() {
    assert_equal "$X7_TO_URL" "$(download -c $X7_TO_URL)" || return 1
}

# Divshare.com

DIVSHARE_URL="http://divshare.com/download/10035476-54f"

test_divshare_download() {
    FILENAME="02 Freedom.mp3"
    assert_equal "$FILENAME" "$(download $DIVSHARE_URL)" || return 1
    rm -f "$FILENAME"
}

test_divshare_check_active_link() {
    assert_equal "$DIVSHARE_URL" "$(download -c $DIVSHARE_URL)" || return 1
}

# dl.free.fr

DL_FREE_FR_URL="http://dl.free.fr/jUeq8Ct2K"

test_dl_free_fr_download() {
    FILENAME="plowshare.txt"
    assert_equal "$FILENAME" "$(download $DL_FREE_FR_URL)" || return 1
    rm -f $FILENAME
}

test_dl_free_fr_check_active_link() {
    assert_equal "$DL_FREE_FR_URL" "$(download -c $DL_FREE_FR_URL)" || return 1
}

# Loadfiles.in

LOADFILES_URL="http://loadfiles.in/95thdkxupzyb/MARKOV2.pdf"

test_loadfiles_download() {
    FILENAME="MARKOV2.pdf"
    assert_equal "$FILENAME" "$(download $LOADFILES_URL)" || return 1
    rm -f "$FILENAME"
}

test_loadfiles_check_active_link() {
    assert_equal "$LOADFILES_URL" "$(download -c $LOADFILES_URL)" || return 1
}

# Humyo.com

HUMYO_URL="http://www.humyo.com/F/6682655-201576855"
HUMYO2_URL="http://www.humyo.com/F/9852859-1634190531"

test_humyo_download() {
    FILENAME="humyo_logo_large.jpg"
    assert_equal "$FILENAME" "$(download $HUMYO_URL)" || return 1
    rm -f "$FILENAME"
}

test_humyo_direct_download() {
    FILENAME="kop_offenbach_standard.pdf"
    assert_equal "$FILENAME" "$(download $HUMYO2_URL)" || return 1
    rm -f "$FILENAME"
}

test_humyo_check_active_link() {
    assert_equal "$HUMYO_URL" "$(download -c $HUMYO_URL)" || return 1
}

test_humyo_check_wrong_link() {
    assert_equal "" "$(download -c ${HUMYO_URL}xyz)" || return 1
}


run_tests "$@"
