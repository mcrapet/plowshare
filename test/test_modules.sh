#!/bin/bash
#
# Test functions for modules (see "modules" directory)
# Copyright (c) 2010 Arnau Sanchez
#
# Note that *-auth files are not in the source code, you need to create
# them with your accounts if you want to run the function test suite.
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

set -e

ROOTDIR=$(dirname $(dirname "$(readlink -f "$0")"))
SRCDIR=$ROOTDIR/src
TESTSDIR=$ROOTDIR/test

source "$SRCDIR/lib.sh"
source "$TESTSDIR/lib.sh"

download() { $SRCDIR/download.sh -q --max-retries=100 "$@"; }

upload() { $SRCDIR/upload.sh -q "$@"; }

delete() { $SRCDIR/delete.sh -q "$@"; }

list() { $SRCDIR/list.sh -q "$@"; }

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

    # manual login
    LOGIN_DATA='username=$USER&password=$PASSWORD'
    COOKIES=$(create_tempfile)
    post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" "$FREEZONE_URL" >/dev/null ||
        { rm -f $COOKIES; return 1; }

    # save number of user's files
    FILES1=$(curl -b "$COOKIES" "$FREEZONE_URL" | parse '<td>Files' '<b>\([^<]*\)')

    URL=$(upload -b "$AUTH" $UPFILE rapidshare)
    assert_match "http://rapidshare.com/files/" "$URL" ||
        { rm -f $COOKIES; return 1; }

    FILES2=$(curl -b "$COOKIES" "$FREEZONE_URL" | parse '<td>Files' '<b>\([^<]*\)')
    rm -f $COOKIE
    assert_equal $((FILES1 + 1)) $FILES2 || return 1
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

MEGAUPLOAD_FOLDER_URL="http://www.megaupload.com/?f=M7L4UC3G"

test_megaupload_list() {
    URLS=$(list $MEGAUPLOAD_FOLDER_URL)
    assert_equal 12 "$(echo "$URLS" | wc -l)"
    assert_equal "http://www.megaupload.com/?d=BIVNP2SM" "$(echo "$URLS" | head -n1)"
}

# 2Shared.com

SHARED_URL="http://www.2shared.com/file/4446939/c9fd70d6/Test.html"

test_2shared_download() {
    FILENAME="Test.mp3"
    assert_equal "$FILENAME" "$(download $SHARED_URL)" || return 1
    rm -f $FILENAME
}

test_2shared_download_using_file_argument_and_mark_as_downloaded() {
    FILENAME='Test.mp3'
    URL="2shared.com/download/4446939/c9fd70d6/Test.mp3"
    TEMP=$(create_tempfile)
    echo "$SHARED_URL" > $TEMP
    assert_match "$FILENAME" $(download -m "$TEMP") || return 1
    assert_match "^# $SHARED_URL" "$(cat $TEMP)" || return 1
    rm -f $FILENAME "$TEMP"
}

test_2shared_check_active_link() {
    assert_equal "$SHARED_URL" "$(download -c $SHARED_URL)" || return 1
}

test_2shared_upload() {
    assert_match "^http://www.2shared.com/file/" "$(upload $UPFILE 2shared)" ||
        return 1
}

# Badongo.com

BADONGO_URL="http://www.badongo.com/file/24361999"

test_badongo_download() {
    FILENAME="RFC-all.tar.gz"
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

test_mediafire_upload_anonymous() {
    URL="$(upload $UPFILE mediafire)"
    assert_match "http://www.mediafire.com/?" "$URL" || return 1
}

# 4shared.com

FSHARED_URL="http://www.4shared.com/file/14767114/7939c436/John_Milton_-_Paradise_Lost.html?s=1"
FSHARED_FOLDER_URL="http://www.4shared.com/dir/3121016/d4ad43ca/desastre_ecologico.html"

test_4shared_download() {
    FILENAME="John_Milton_-_Paradise_Lost.pdf"
    assert_equal "$FILENAME" "$(download $FSHARED_URL)" || return 1
    rm -f $FILENAME
}

test_4shared_check_active_link() {
    assert_equal "$FSHARED_URL" "$(download -c $FSHARED_URL)" || return 1
}

test_4shared_list() {
    URLS=$(list $FSHARED_FOLDER_URL)
    assert_equal 9 "$(echo "$URLS" | wc -l)"
    assert_equal "http://www.4shared.com/file/HOiDzifg/DIS_ECOpart01.html" \
      "$(echo "$URLS" | head -n1)"
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

DEPOSIT_URL="http://depositfiles.com/en/files/xn88ws0rr"

test_depositfiles_check_active_link() {
    assert_equal "$DEPOSIT_URL" "$(download -c $DEPOSIT_URL)" || return 1
}

test_depositfiles_download() {
    FILENAME="RFC-all.tar.gz"
    assert_equal "$FILENAME" "$(download $DEPOSIT_URL)" || return 1
    rm -f $FILENAME
}

# Storage.to

STORAGE_TO_URL="http://www.storage.to/get/dFempNyH/plowshare.bin"

test_storage_to_download() {
    FILENAME="plowshare.bin"
    assert_equal "$FILENAME" "$(download $STORAGE_TO_URL)" || return 1
    rm -f $FILENAME
}

test_storage_to_check_active_link() {
    assert_equal "$STORAGE_TO_URL" "$(download -c $STORAGE_TO_URL)" || return 1
}

# Netload.in

NETLOAD_IN_URL="http://netload.in/dateiuPaLpfQU1r/RFC-all.tar.gz.htm"

test_netload_in_download() {
    FILENAME="RFC-all.tar.gz"
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
    FILENAME="RFCs0001-0500.tar.gz"
    assert_equal "$FILENAME" "$(download $USERSHARE_URL)" || return 1
    rm -f $FILENAME
}

test_usershare_check_active_link() {
    assert_equal "$USERSHARE_URL" "$(download -c $USERSHARE_URL)" || return 1
}

# Sendspace.net

SENDSPACE_URL="http://www.sendspace.com/file/jixw4t"

test_sendspace_download() {
    FILENAME="plowshare.bin"
    assert_equal "$FILENAME" "$(download $SENDSPACE_URL)" || return 1
    rm -f $FILENAME
}

test_sendspace_check_active_link() {
    assert_equal "$SENDSPACE_URL" "$(download -c $SENDSPACE_URL)" || return 1
}

SENDSPACE_FOLDER_URL="http://www.sendspace.com/folder/w0uxuo"

test_sendspace_list() {
    URLS=$(list $SENDSPACE_FOLDER_URL)
    assert_equal 8 "$(echo "$URLS" | wc -l)"
    assert_equal "http://www.sendspace.com/file/lpcqke" "$(echo "$URLS" | head -n1)"
}

# x7.to

X7_TO_URL="http://x7.to/rdfiqb"

test_x7_to_download() {
    FILENAME="plowshare.bin"
    assert_equal "$FILENAME" "$(download $X7_TO_URL)" || return 1
    rm -f $FILENAME
}

test_x7_to_check_active_link() {
    assert_equal "$X7_TO_URL" "$(download -c $X7_TO_URL)" || return 1
}

# Divshare.com

DIVSHARE_URL="http://www.divshare.com/download/11577646-29a"

test_divshare_download() {
    FILENAME="plowshare.abc"
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

# Data.hu

DATA_HU_URL="http://data.hu/get/2341285/Telekia.part01.rar.html"

test_data_hu_download() {
    FILENAME="Telekia.part01.rar"
    assert_equal "$FILENAME" "$(download $DATA_HU_URL)" || return 1
    rm -f "$FILENAME"
}

test_data_hu_check_active_link() {
    assert_equal "$DATA_HU_URL" "$(download -c $DATA_HU_URL)" || return 1
}

test_data_hu_check_wrong_link() {
    assert_equal "" "$(download -c ${DATA_HU_URL/234/wronglink})" || return 1
}

# Filesonic/Sharingmatrix

FILESONIC_FILE_URL='http://www.filesonic.com/file/19850743/sharingmatrixtest.bin'
FILESONIC_FAKE_URL='http://www.filesonic.com/file/12345678/fake.bin'
FILESONIC_DELETED_URL='http://www.filesonic.com/file/19851449/sharingmatrixtestdeleted.bin'
FILESONIC_FOLDER_URL='http://www.filesonic.com/folder/312319'

test_filesonic_check_active_link() {
    assert_equal "$FILESONIC_FILE_URL" "$(download -c $FILESONIC_FILE_URL)" || return 1
}

test_filesonic_list() {
    URLS=$(list $FILESONIC_FOLDER_URL)
    assert_equal 2 "$(echo "$URLS" | wc -l)"
    assert_equal "http://www.filesonic.com/file/19850743/sharingmatrixtest.bin" \
      "$(echo "$URLS" | head -n1)"
}

test_filesonic_download() {
    FILENAME="sharingmatrixtest.bin"
    assert_equal "$FILENAME" "$(download $FILESONIC_FILE_URL)" || return 1
    rm -f $FILENAME
}

test_filesonic_deleted() {
    assert_equal "Warning: file link is not alive" "$($SRCDIR/download.sh -c $FILESONIC_DELETED_URL 2>&1 )" || return 1
}

test_filesonic_wrong_link() {
    assert_equal "" "$(download -c ${FILESONIC_FAKE_URL})" || return 1
}

# 115.com

TEST_115_URL='http://u.115.com/file/t0df93ba8d'

test_115_download() {
    FILENAME='%E5%98%BF%E5%98%BF%E9%BB%91.rar'
    assert_equal "$FILENAME" "$(download $TEST_115_URL)" || return 1
    rm -f "$FILENAME"
}


run_tests "$@"
