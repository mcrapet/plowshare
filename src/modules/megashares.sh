# Plowshare megashares.com module
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

MODULE_MEGASHARES_REGEXP_URL='http://\(www\.\)\?d01\.megashares\.com/'

MODULE_MEGASHARES_DOWNLOAD_OPTIONS=""
MODULE_MEGASHARES_DOWNLOAD_RESUME=yes
MODULE_MEGASHARES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_MEGASHARES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_MEGASHARES_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
CATEGORY,,category,s=CATEGORY,Upload category
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
PRIVATE_FILE,,private,,Do not make file searchable/public
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_MEGASHARES_UPLOAD_REMOTE_SUPPORT=no

MODULE_MEGASHARES_DELETE_OPTIONS=""
MODULE_MEGASHARES_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
megashares_login() {
    local AUTH_FREE=$1
    local COOKIEFILE=$2
    local LOGIN_DATA PAGE NAME REDIR

    LOGIN_DATA='httpref=&mymslogin_name=$USER&mymspassword=$PASSWORD&myms_login=Login'

    # include header in output to check for redirect
    PAGE=$(post_login "$AUTH_FREE" "$COOKIEFILE" "$LOGIN_DATA" \
       'http://d01.megashares.com/myms_login.php' --include) || return

    REDIR=$(echo "$PAGE" | grep_http_header_location_quiet)

    if [ "$REDIR" = 'http://d01.megashares.com/myms.php' ]; then
        : # everything ok
    elif match 'Login failed for user' "$PAGE"; then
        return $ERR_LOGIN_FAILED
    # You have not verified your account yet.
    elif matchi 'activation link' "$PAGE"; then
        return $ERR_LOGIN_FAILED
    else
        log_error 'Problem during login, site updated?'
        return $ERR_FATAL
    fi

    # Note: success full login also creates cookie 'myms' which
    # starts with 'NAME%...'
    NAME=$(parse_cookie 'myms' < "$COOKIEFILE") || return

    log_debug "Successfully logged in as member '${NAME%%%*}'"
}

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

# Convert a decimal number into its base32hex representation
# Note: conversion to ASCII is from core.sh (random)
#
# $1: decimal number
# stdout: $1 converted into base32hex
dec_to_base32hex() {
    local NUM=$1
    local BASE=32
    local CONV REM QUOT

    # Catch special case NUM == 0
    if (( NUM == 0 )); then
        echo 0
        return
    fi

    while (( NUM > 0 )); do
        (( REM = NUM % BASE ))
        (( QUOT = NUM / BASE ))

        if (( REM >= 10 )); then
            # convert to (lower case) ASCII
            (( REM += 16#61 - 10 )) # 10 => a, 11 => b, 12 => c, ...
            REM=$(printf \\$(($REM/64*100+$REM%64/8*10+$REM%8)))
        fi

        CONV=$REM$CONV # prepend the new digit (no math mode!)
        NUM=$QUOT
    done
    echo $CONV
}

# Output megashares.com file download URL
# $1: cookie file (unused here)
# $2: megashares.com url
# stdout: real file download link
megashares_download() {
    local URL=$2
    local FID URL PAGE BASEURL QUOTA_LEFT FILE_SIZE FILE_URL FILE_NAME

    BASEURL=$(basename_url "$URL")

    # Two kinds of URL:
    # http://d01.megashares.com/?d01=8Ptv172
    # http://d01.megashares.com/dl/2eb56b0/Filename.rar
    FID=$(echo "$2" | parse_quiet '/dl/' 'dl/\([^/]*\)')
    if [ -n "$FID" ]; then
        URL="http://d01.megashares.com/index.php?d01=$FID"
    fi

    PAGE=$(curl "$URL") || return

    # Check for dead link
    if matchi 'file does not exist\|link was removed due to' "$PAGE"; then
        return $ERR_LINK_DEAD
    # All download slots for this link are currently filled.
    # Please try again momentarily.
    elif matchi 'try again momentarily' "$PAGE"; then
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    # You have reached your maximum download limit
    elif matchi 'maximum download limit' "$PAGE"; then
        log_debug 'You have reached your maximum download limit.'
        #declare -i MIN=10#$(echo "$PAGE" | parse 'in 00:' 'g>\([[:digit:]]*\)</strong>:')
        #echo $((60 * MIN)) minutes
        echo 600
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi


    # Captcha must be validated
    if match 'Security Code' "$PAGE"; then
        local MTIME CAPTCHA_URL

        # 68x18 png file. Cookie file is not required (for curl)
        CAPTCHA_URL=$(echo "$PAGE" | parse_attr 'Security Code' src) || return

        local WI WORD ID
        WI=$(captcha_process "$BASEURL/$CAPTCHA_URL" digits 4) || return
        { read WORD; read ID; } <<<"$WI"

        if [ "${#WORD}" -lt 4 ]; then
            captcha_nack $ID
            log_debug 'captcha length invalid'
            return $ERR_CAPTCHA
        elif [ "${#WORD}" -gt 4 ]; then
            WORD="${WORD:0:4}"
        fi

        log_debug "decoded captcha: $WORD"

        RANDOM_NUM=$(echo "$PAGE" | parse_attr 'random_num' 'value')
        PASSPORT_NUM=$(echo "$PAGE" | parse_attr 'passport_num' 'value')
        # Javascript: "now = new Date(); print(now.getTime());"
        MTIME="$(date +%s)000"

        # Get passport
        VALIDATE_PASSPORT=$(curl --get \
            -d "rs=check_passport_renewal" \
            -d "rsargs[]=${WORD}&rsargs[]=${RANDOM_NUM}&rsargs[]=${PASSPORT_NUM}&rsargs[]=replace_sec_pprenewal" \
            -d "rsrnd=$MTIME" \
            "$URL") || return

        if ! match 'Thank you for reactivating your passport' "$VALIDATE_PASSPORT"; then
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug 'correct captcha'
    fi

    QUOTA_LEFT=`parse_kilobytes $(echo "$PAGE" | grep '[KMG]B' | last_line)`
    FILE_SIZE=`parse_kilobytes $(echo "$PAGE" | parse 'Filesize:' 'g> \([0-9.]*[[:space:]]*[KMG]\)')`

    # This link's filesize is larger than what you have left on your Passport.
    if [ "$QUOTA_LEFT" -lt "$FILE_SIZE" ]; then
        log_error 'Cannot retrieve file entirely, but start anyway'
        log_debug "quota left: $QUOTA_LEFT (required: $FILE_SIZE)"
    fi

    FILE_NAME=$(echo "$PAGE" | parse_attr '<h1' 'title')
    FILE_URL=$(echo "$PAGE" | parse_attr 'download_file.png' 'href') || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to megashares.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: megashares download + delete link
megashares_upload() {
    local COOKIEFILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASEURL='http://www.megashares.com'
    local MAX_SIZE=$((10000*1024*1024)) # up to 10000MB

    local PAGE DL_LINK DEL_LINK OPT_PUB OPT_CAT
    local UPLOAD_URL FILE_SIZE UPLOAD_ID FILE_ID I RND DATE

    # Check file size
    FILE_SIZE=$(get_filesize "$FILE")
    if [ $FILE_SIZE -gt $MAX_SIZE ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Login comes first (will invalidate upload URL otherwise)
    if [ -n "$AUTH_FREE" ]; then
        megashares_login "$AUTH_FREE" "$COOKIEFILE" || return
    fi

    # Note: Megashares uses Plupload -- http://www.plupload.com/
    PAGE=$(curl -c "$COOKIEFILE" -b "$COOKIEFILE" "$BASEURL") || return

    # If user chose a category, check it now
    if [ -n "$CATEGORY" ]; then
        local CAT_ALL

        # strUploadCategoryHTML += '<option selected="" value="doc">Document</option>';
        CAT_ALL=$(echo "$PAGE" | parse_all_attr option value) || return

        if [ -z "$CAT_ALL" ]; then
            log_error 'No categories found, site updated?'
            return $ERR_FATAL
        fi

        log_debug "available categories:" $CAT_ALL

        for CAT in $CAT_ALL; do
            if [ "$CAT" == "$CATEGORY" ]; then
                OPT_CAT=$CAT
                break
            fi
        done

        if [ -z "$OPT_CAT" ]; then
            log_error "Category '$CATEGORY' invalid; choose from:" $CAT_ALL
            return $ERR_BAD_COMMAND_LINE
        fi
    else
        OPT_CAT='doc' # Use site's default if user didn't choose
        log_debug "using default upload category ($OPT_CAT)"
    fi

    # Retrieve unique upload URL
    UPLOAD_URL=$(echo "$PAGE" | parse '^[[:space:]]\+url :' \
        "url : '\(.\+\)' ,$") || return

    log_debug "category: $OPT_CAT"
    log_debug "upload URL: $UPLOAD_URL"

    # File ID is created this way (from plugload.js):
    #     guid:function(){
    #       var n=new Date().getTime().toString(32),o;
    #       for(o=0;o<5;o++){
    #        n+=Math.floor(Math.random()*65535).toString(32)
    #       }
    #       return(g.guidPrefix||"p")+n+(f++).toString(32)
    #     }
    # with:
    #     g.guidPrefix == NULL
    #     f==4 (for the first file)
    #
    # Example: p16un8pgstjbi1vt71utd1iak1smh4
    DATE=$(date +%s000)
    UPLOAD_ID=$(dec_to_base32hex $DATE)

    for I in 1 2 3 4 5; do
        RND=$(random u16)
        RND=$(dec_to_base32hex $RND)
        UPLOAD_ID=$UPLOAD_ID$RND
    done

    UPLOAD_ID="p${UPLOAD_ID}4"
    log_debug "upload ID: $UPLOAD_ID"

    # Pre-upload file check + register upload ID at server
    PAGE=$(curl -b "$COOKIEFILE" \
        -d "uploading_files[0][id]=$UPLOAD_ID" \
        -d "uploading_files[0][name]=$DESTFILE" \
        -d "uploading_files[0][size]=$FILE_SIZE" \
        -d 'uploading_files[0][loaded]=0' \
        -d 'uploading_files[0][percent]=0' \
        -d 'uploading_files[0][status]=1' \
        "$BASEURL/pre_upload.php") || return

    if [ "$PAGE" != 'success' ]; then
        log_error "Remote error during pre upload check: $PAGE"
        return $ERR_FATAL
    fi

    # Publish file?
    if [ -n "$PRIVATE_FILE" ]; then
        OPT_PUB='off'
    else
        OPT_PUB='on'
    fi

    # Notes:
    # - "name" consists of upload ID + real file extension
    # - to make link non searchable/public, use "searchable=off"
    PAGE=$(curl_with_log -b "$COOKIEFILE" \
        -F "name=$UPLOAD_ID.${DESTFILE##*.}" \
        --form-string "uploadFileDescription=$DESCRIPTION" \
        --form-string "passProtectUpload=$LINK_PASSWORD" \
        -F "uploadFileCategory=$OPT_CAT" \
        -F "searchable=$OPT_PUB" \
        --form-string "emailAddress=$TOEMAIL" \
        -F "file=@$FILE;filename=$DESTFILE" \
        "$UPLOAD_URL") || return

    # Server returns some file ID only
    FILE_ID=$(echo "$PAGE" | parse . '^\([[:digit:]]\+\)$') || return
    log_debug "file ID: $FILE_ID"

    # Retrieve actual links
    PAGE=$(curl -b "$COOKIEFILE" \
        "$BASEURL/upostfile.php?fid=$FILE_ID") || return

    # <dt>Download Link to share:</dt>
    DL_LINK=$(echo "$PAGE" | parse_tag '/dl/' a)

    # <dt>Delete Link (keep this in a safe place):</dt>
    DEL_LINK=$(echo "$PAGE" | parse_tag '?dl=' a)

    echo "$DL_LINK"
    echo "$DEL_LINK"
}

# Delete a file from megashares.com
# $1: cookie file (unused here)
# $2: megashares.com (delete) link
megashares_delete() {
    local URL=$2
    local PAGE FORM_HTML FORM_ACTION

    PAGE=$(curl -L "$URL") || return

    # Link has already been deleted.
    # Link not found. Meaning it is not in our DB so the supplied d01 is invalid.
    if matchi 'already been deleted\|link not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif ! match 'id="deleteConfirm"' "$PAGE"; then
        log_error 'This is not a delete link'
        return $ERR_FATAL
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE")
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action | html_to_utf8) || return

    # HTTP POST request
    PAGE=$(curl --data '' "http://d01.megashares.com$FORM_ACTION") || return

    # Link successfully deleted.
    match 'successfully deleted' "$PAGE" || return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: Megashares url
# $3: requested capability list
# stdout: 1 capability per line
megashares_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local URL PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L "$URL") || return

    # Site won't show any info if no download slot is available :-(
    if match 'try again momentarily' "$PAGE"; then
        echo 120
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    matchi 'file does not exist\|link was removed due to' "$PAGE" && return $ERR_LINK_DEAD
    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$PAGE" | parse_attr '<h1' 'title' && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse 'Filesize:' \
            '[[:blank:]]\([[:digit:]]\+\(.[[:digit:]]\+\)\?[[:blank:]][KMG]\?B\)\(ytes\)\?') && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    # also available: file description

    echo $REQ_OUT
}
