#!/bin/bash
#
# megashares.com module
# Copyright (c) 2011 Plowshare team
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

MODULE_MEGASHARES_REGEXP_URL="http://\(www\.\)\?d01\.megashares\.com/"

MODULE_MEGASHARES_DOWNLOAD_OPTIONS=""
MODULE_MEGASHARES_DOWNLOAD_RESUME=yes
MODULE_MEGASHARES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_MEGASHARES_UPLOAD_OPTIONS="
DESCRIPTION,d:,description:,DESCRIPTION,Set file description
LINK_PASSWORD,p:,link-password:,PASSWORD,Protect a link with a password
EMAIL,,email:,EMAIL,Field for notification email"

# $1: floating point number (example: "513.58")
# $2: unit (KB | MB | GB)
# stdout: fixed point number (in kilobytes)
parse_kilobytes() {
    declare -i R=10#${1%.*}
    declare -i F=10#${1#*.}

    if test "${2:0:1}" = "G"; then
        echo $(( 1000000 * R + 1000 * F))
    elif test "${2:0:1}" = "K"; then
        echo $(( R ))
    else
        echo $(( 1000 * R + F))
    fi
}

# Output megashares.com file download URL
# $1: cookie file (unused here)
# $2: megashares.com url
# stdout: real file download link
megashares_download() {
    eval "$(process_options megashares "$MODULE_MEGASHARES_DOWNLOAD_OPTIONS" "$@")"

    local URL="$2"
    local ID URL PAGE BASEURL

    PERL_PRG=$(detect_perl) || return
    BASEURL=$(basename_url "$URL")

    # Two kind of URL:
    # http://d01.megashares.com/?d01=8Ptv172
    # http://d01.megashares.com/dl/2eb56b0/Filename.rar
    ID=$(echo "$2" | parse_quiet '\/dl\/' 'dl\/\([^/]*\)')
    if [ -n "$ID" ]; then
        URL="http://d01.megashares.com/index.php?d01=$ID"
    fi

    PAGE=$(curl "$URL") || return

    # Check for dead link
    if matchi 'file does not exist\|invalid link' "$PAGE"; then
        log_debug "File not found"
        return $ERR_LINK_DEAD
    # All download slots for this link are currently filled.
    # Please try again momentarily.
    elif matchi 'try again momentarily' "$PAGE"; then
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    test "$CHECK_LINK" && return 0

    # Test maximum download limit
    while match 'You have reached your maximum download limit' "$PAGE"; do
        log_debug 'You have reached your maximum download limit.'
        #declare -i MIN=10#$(echo "$PAGE" | parse 'in 00:' 'g>\([[:digit:]]*\)<\/strong>:')
        #wait $((MIN + 1)) minutes || return
        wait 10 minutes
        PAGE=$(curl "$URL") || return
    done

    # Captcha must be validated
    if match 'Security Code' "$PAGE"; then
        while retry_limit_not_reached || return; do
            CAPTCHA_URL=$BASEURL/$(echo "$PAGE" | parse_attr 'Security Code' 'src')

            # Create new formatted image
            CAPTCHA_IMG=$(create_tempfile) || return
            curl "$CAPTCHA_URL" | $PERL_PRG $LIBDIR/strip_single_color.pl | \
                    convert - -quantize gray -colors 32 -blur 10% -contrast-stretch 6% \
                    -compress none -level 45%,45% tif:"$CAPTCHA_IMG" || { \
                rm -f "$CAPTCHA_IMG";
                return $ERR_CAPTCHA;
            }

            CAPTCHA=$(captcha_process "$CAPTCHA_IMG" ocr_digit) || return
            rm -f "$CAPTCHA_IMG"

            test "${#CAPTCHA}" -gt 4 && CAPTCHA="${CAPTCHA:0:4}"
            log_debug "Decoded captcha: $CAPTCHA"

            if [ "${#CAPTCHA}" -ne 4 ]; then
                log_debug "Captcha length invalid"
                PAGE=$(curl "$URL") || return
                continue
            fi

            RANDOM_NUM=$(echo "$PAGE" | parse_attr 'random_num' 'value')
            PASSPORT_NUM=$(echo "$PAGE" | parse_attr 'passport_num' 'value')
            MTIME="$(date +%s)000"

            # Get passport
            VALIDATE_PASSPORT=$(curl --get \
                    --data "rs=check_passport_renewal&rsargs[]=${CAPTCHA}&rsargs[]=${RANDOM_NUM}&rsargs[]=${PASSPORT_NUM}&rsargs[]=replace_sec_pprenewal&rsrnd=$MTIME" \
                    $URL)

            match 'Thank you for reactivating your passport' "$VALIDATE_PASSPORT" && break

            log_debug "Wrong captcha"
            PAGE=$(curl "$URL") || return
        done
        log_debug "Correct captcha!"
    fi

    QUOTA_LEFT=`parse_kilobytes $(echo "$PAGE" | grep '[KMG]B' | last_line)`
    FILE_SIZE=`parse_kilobytes $(echo "$PAGE" | parse 'Filesize:' 'g> \([0-9.]*[[:space:]]*[KMG]\)')`

    # This link's filesize is larger than what you have left on your Passport.
    if [ "$QUOTA_LEFT" -lt "$FILE_SIZE" ]; then
        log_debug "cannot retrieve file entirely, but start anyway"
        log_debug "quota left: $QUOTA_LEFT (required: $FILE_SIZE)"
    fi

    FILEURL=$(echo "$PAGE" | parse_attr 'download_file.png' 'href')
    echo "$FILEURL"
}

# Upload a file to megashares.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: megashares download + delete link
megashares_upload() {
    eval "$(process_options megashares "$MODULE_MEGASHARES_UPLOAD_OPTIONS" "$@")"

    local FILE="$2"
    local DESTFILE="$3"
    local BASEURL="http://www.megashares.com"

    local PAGE CATEGORY SEARCH DL_LINK DEL_LINK

    PAGE=$(curl "$BASEURL") || return

    # Upload Category: video doc application music image
    CATEGORY='video'

    # Note: To make link non searchable/public, delete "searchable=on" line.
    # Putting "off" or any other value means "enabled".

    APC_UPLOAD_PROGRESS=$(echo "$PAGE" | parse_attr 'name="APC_UPLOAD_PROGRESS"' 'value')
    MSUP_ID=$(echo "$PAGE" | parse_attr 'name="msup_id"' 'value')
    DOWNLOADPROGRESSURL=$(echo "$PAGE" | parse_attr 'name="downloadProgressURL"' 'value')
    ULOC=$(echo "$PAGE" | parse_attr 'id="uloc"' 'value')
    TMP_SID=$(echo "$PAGE" | parse_attr 'id="tmp_sid"' 'value')
    UPS_SID=$(echo "$PAGE" | parse_attr 'id="ups_sid"' 'value')

    PAGE=$(curl_with_log \
        -F "APC_UPLOAD_PROGRESS=$APC_UPLOAD_PROGRESS" \
        -F "msup_id=$MSUP_ID" \
        -F "downloadProgressURL=$DOWNLOADPROGRESSURL" \
        -F "uploadFileCategory=$CATEGORY" \
        -F "uploadFileDescription=$DESCRIPTION" \
        -F "passProtectUpload=$LINK_PASSWORD" \
        -F "searchable=on" \
        -F "emailAddress=$EMAIL" \
        -F "upfile_0=@$FILE;filename=$DESTFILE" \
        -F "checkTOS=" \
        "$BASEURL/uploader.php?tmp_sid=$TMP_SID&ups_sid=$UPS_SID&uld=$ULOC&uloc=$ULOC") || return

    DL_LINK=$(echo "$PAGE" | parse 'dlLink' '>\([^<]*\)<\/div>')
    DEL_LINK=$(echo "$PAGE" | parse 'delLink' '>\([^<]*\)<\/div>')

    echo "$DL_LINK ($DEL_LINK)"
}
