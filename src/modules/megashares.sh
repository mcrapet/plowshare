#!/bin/bash
#
# megashares.com module
# Copyright (c) 2011-2012 Plowshare team
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
TOEMAIL,,email-to:,EMAIL,<To> field for notification email"
MODULE_MEGASHARES_UPLOAD_REMOTE_SUPPORT=no

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
    local ID URL PAGE BASEURL QUOTA_LEFT FILE_SIZE FILE_URL FILE_NAME

    detect_perl || return

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
        return $ERR_LINK_DEAD
    # All download slots for this link are currently filled.
    # Please try again momentarily.
    elif matchi 'try again momentarily' "$PAGE"; then
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    # You have reached your maximum download limit
    elif matchi 'maximum download limit' "$PAGE"; then
        log_debug 'You have reached your maximum download limit.'
        #declare -i MIN=10#$(echo "$PAGE" | parse 'in 00:' 'g>\([[:digit:]]*\)<\/strong>:')
        #echo $((60 * MIN)) minutes
        echo 600
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    test "$CHECK_LINK" && return 0

    # Captcha must be validated
    if match 'Security Code' "$PAGE"; then
        CAPTCHA_URL=$BASEURL/$(echo "$PAGE" | parse_attr 'Security Code' 'src')

        # Create new formatted image
        CAPTCHA_IMG=$(create_tempfile) || return
        curl "$CAPTCHA_URL" | perl 'strip_single_color.pl' | \
                convert - -quantize gray -colors 32 -blur 10% -contrast-stretch 6% \
                -compress none -level 45%,45% tif:"$CAPTCHA_IMG" || { \
            rm -f "$CAPTCHA_IMG";
            return $ERR_CAPTCHA;
        }

        CAPTCHA=$(captcha_process "$CAPTCHA_IMG" ocr_digit) || return
        rm -f "$CAPTCHA_IMG"

        if [ "${#CAPTCHA}" -lt 4 ]; then
            log_debug "captcha length invalid"
            return $ERR_CAPTCHA
        elif [ "${#CAPTCHA}" -gt 4 ]; then
            CAPTCHA="${CAPTCHA:0:4}"
        fi
        log_debug "decoded captcha: $CAPTCHA"

        RANDOM_NUM=$(echo "$PAGE" | parse_attr 'random_num' 'value')
        PASSPORT_NUM=$(echo "$PAGE" | parse_attr 'passport_num' 'value')
        # Javascript: "now = new Date(); print(now.getTime());"
        MTIME="$(date +%s)000"

        # Get passport
        VALIDATE_PASSPORT=$(curl --get \
                --data "rs=check_passport_renewal&rsargs[]=${CAPTCHA}&rsargs[]=${RANDOM_NUM}&rsargs[]=${PASSPORT_NUM}&rsargs[]=replace_sec_pprenewal&rsrnd=$MTIME" \
                $URL)

        if ! match 'Thank you for reactivating your passport' "$VALIDATE_PASSPORT"; then
            log_error "Wrong captcha"
            return $ERR_CAPTCHA
        fi

        log_debug "correct captcha"
    fi

    QUOTA_LEFT=`parse_kilobytes $(echo "$PAGE" | grep '[KMG]B' | last_line)`
    FILE_SIZE=`parse_kilobytes $(echo "$PAGE" | parse 'Filesize:' 'g> \([0-9.]*[[:space:]]*[KMG]\)')`

    # This link's filesize is larger than what you have left on your Passport.
    if [ "$QUOTA_LEFT" -lt "$FILE_SIZE" ]; then
        log_error "Cannot retrieve file entirely, but start anyway"
        log_debug "quota left: $QUOTA_LEFT (required: $FILE_SIZE)"
    fi

    FILE_NAME=$(echo "$PAGE" | parse_attr '<h1' 'title')
    FILE_URL=$(echo "$PAGE" | parse_attr 'download_file.png' 'href')

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to megashares.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: megashares download + delete link
megashares_upload() {
    eval "$(process_options megashares "$MODULE_MEGASHARES_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local FILE="$2"
    local DESTFILE="$3"
    local BASEURL='http://www.megashares.com'

    local PAGE CATEGORY DL_LINK DEL_LINK

    PAGE=$(curl -c "$COOKIEFILE" "$BASEURL") || return

    # Upload Category: video doc application music image
    CATEGORY='video'

    # Note: To make link non searchable/public, delete "searchable=on" line.
    # Putting "off" or any other value means "enabled".

    local FORM_HTML APC_UPLOAD_PROGRESS MSUP_IDD OWNLOADPROGRESSURL
    FORM_HTML=$(grep_form_by_name "$PAGE" 'form_upload')
    APC_UPLOAD_PROGRESS=$(echo "$FORM_HTML" | parse_form_input_by_name 'APC_UPLOAD_PROGRESS')
    MSUP_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'msup_id')
    DOWNLOADPROGRESSURL=$(echo "$FORM_HTML" | parse_form_input_by_name 'downloadProgressURL')
    ULOC=$(echo "$FORM_HTML" | parse_form_input_by_id 'uloc')
    TMP_SID=$(echo "$FORM_HTML" | parse_form_input_by_id 'tmp_sid')
    UPS_SID=$(echo "$FORM_HTML" | parse_form_input_by_id 'ups_sid')

    PAGE=$(curl_with_log -b "$COOKIEFILE" \
        -F "APC_UPLOAD_PROGRESS=$APC_UPLOAD_PROGRESS" \
        -F "msup_id=$MSUP_ID" \
        -F "downloadProgressURL=$DOWNLOADPROGRESSURL" \
        -F "uploadFileCategory=$CATEGORY" \
        --form-string "uploadFileDescription=$DESCRIPTION" \
        --form-string "passProtectUpload=$LINK_PASSWORD" \
        --form-string "emailAddress=$TOEMAIL" \
        -F "searchable=on" \
        -F "upfile_0=@$FILE;filename=$DESTFILE" \
        -F "checkTOS=1" \
        -F "uploadFileURL=" \
        "$BASEURL/9999.php?tmp_sid=$TMP_SID&ups_sid=$UPS_SID&uld=$ULOC&uloc=$ULOC") || return

    # <body><div id='uplMsg'>error</div><div id='err-message'>Error on upload</div></body>
    if match 'err-message' "$PAGE"; then
        local ERR=$(echo "$PAGE" | parse_quiet 'err-message' "message'>\([^<]*\)")
        log_error "upload failure ($ERR)"
        return $ERR_FATAL
    fi

    # <script type="text/javascript">eval('parent.location = "http://www.megashares.com/upostproc.php?fid=25936274"');</script>
    local URL
    URL=$(echo "$PAGE" | parse 'location' '= "\(http[^"]*\)')
    PAGE=$(curl -b "$COOKIEFILE" "$URL") || return

    # <dt>Download Link to share:</dt>
    DL_LINK=$(echo "$PAGE" | parse_tag '\/dl\/' a)

    # Needs "uloader" entry in cookie file to get delete link
    # <dt>Delete Link (keep this in a safe place):</dt>
    DEL_LINK=$(echo "$PAGE" | parse_tag '?dl=' a)

    echo "$DL_LINK"
    echo "$DEL_LINK"
}
