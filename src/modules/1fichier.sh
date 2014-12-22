# Plowshare 1fichier.com module
# Copyright (c) 2011 halfman <Pulpan3@gmail.com>
# Copyright (c) 2012-2014 Plowshare team
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

MODULE_1FICHIER_REGEXP_URL='https\?://\(.*\.\)\?\(1fichier\.\(com\|net\|org\|fr\)\|alterupload\.com\|cjoint\.\(net\|org\)\|desfichiers\.\(com\|net\|org\|fr\)\|dfichiers\.\(com\|net\|org\|fr\)\|megadl\.fr\|mesfichiers\.\(net\|org\)\|piecejointe\.\(net\|org\)\|pjointe\.\(com\|net\|org\|fr\)\|tenvoi\.\(com\|net\|org\)\|dl4free\.com\)'

MODULE_1FICHIER_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,Premium account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_1FICHIER_DOWNLOAD_RESUME=yes
MODULE_1FICHIER_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_1FICHIER_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_1FICHIER_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
MESSAGE,d,message,S=MESSAGE,Set file message (is send with notification email)
DOMAIN,,domain,N=ID,You can set domain ID to upload (ID can be found at http://www.1fichier.com/en/api/web.html)
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_1FICHIER_UPLOAD_REMOTE_SUPPORT=no

MODULE_1FICHIER_LIST_OPTIONS=""
MODULE_1FICHIER_LIST_HAS_SUBFOLDERS=no

MODULE_1FICHIER_DELETE_OPTIONS=""
MODULE_1FICHIER_PROBE_OPTIONS=""

# Static function. Proceed with login
1fichier_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT SID

    LOGIN_DATA='mail=$USER&pass=$PASSWORD&lt=on&secure=on&Login=Login'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.pl") || return

    # You are logged in. This page will redirect you.

    SID=$(parse_cookie_quiet 'SID' < "$COOKIE_FILE") || return
    [ -n "$SID" ] || return $ERR_LOGIN_FAILED

    #PAGE=$(curl -b "$COOKIE_FILE" -b 'LG=en' 'https://1fichier.com/console/index.pl') || return
}

# Static function. Proper way to get file information
# $1: 1fichier url
# stdout: string (with ; as separator)
1fichier_checklink() {
    local S FID
    S=$(curl --form-string "links[]=$1" 'https://1fichier.com/check_links.pl') || return

    # Note: Password protected links return
    # url;;;PRIVATE
    if [ "${S##*;}" = 'BAD LINK' ]; then
        log_debug 'obsolete link format?'
        return $ERR_LINK_DEAD
    elif [ "${S##*;}" = 'NOT FOUND' ]; then
        return $ERR_LINK_DEAD
    fi

    echo "$S"
}

# Output a 1fichier file download URL
# $1: cookie file (account only)
# $2: 1fichier url
# stdout: real file download link
#
# Note: Consecutive HTTP requests must be delayed (>10s).
#       Otherwise you'll get the parallel download message.
1fichier_download() {
    local -r COOKIE_FILE=$1
    local URL=$(replace 'http://' 'https://' <<< "$2")
    local FID PAGE FILE_URL FILE_NAME WAIT

    FID=$(parse_quiet . '://\([[:alnum:]]*\)\.' <<< "$URL")
    if [ -n "$FID" ] && [ "$FID" != '1fichier' ]; then
        URL="https://1fichier.com/?$FID"
    fi

    if [ -n "$AUTH" ]; then
        1fichier_login "$AUTH" "$COOKIE_FILE" 'https://1fichier.com' || return
    fi

    FILE_URL=$(curl --head -b "$COOKIE_FILE" "$URL" | \
        grep_http_header_location_quiet)

    PAGE=$(1fichier_checklink "$URL") || return
    IFS=';' read -r _ FILE_NAME _ <<< "$PAGE"

    if [ -z "$FILE_NAME" ]; then
        log_error 'This must be a direct download link with password, filename will be wrong!'
    fi

    if [ -n "$FILE_URL" ]; then
        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0
    fi

    PAGE=$(curl -b 'LG=en' "$URL") || return

    # Location: http://www.1fichier.com/?c=SCAN
    if match 'MOVED - TEMPORARY_REDIRECT' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # The requested file could not be found
    # The file may have been deleted by its owner.
    # The requested file has been deleted following an abuse request.
    if match 'The \(requested \)\?file \(could not be found\|.*been deleted\)' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # Warning ! Without premium status, you can download only one file at a time
    if match 'Warning ! Without premium status,' "$PAGE"; then
        log_error 'No parallel download allowed.'
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE

    # Warning ! Without Premium, you must wait between downloads.<br/>You must wait 9 minutes</div>
    elif match 'Warning ! Without Premium,' "$PAGE"; then
        WAIT=$(parse 'Warning ! Without' 'You must wait \([[:digit:]]\+\) minute' <<< "$PAGE")
        echo $((WAIT * 60))
        return $ERR_LINK_TEMP_UNAVAILABLE

    # Please wait until the file has been scanned by our anti-virus
    elif match 'Please wait until the file has been scanned' "$PAGE"; then
        log_error 'File is scanned for viruses.'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Accessing this file is protected by password.<br/>Please put it on the box bellow :
    if match 'name="pass"' "$PAGE"; then
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        FILE_URL=$(curl -i -F "pass=$LINK_PASSWORD" "$URL" | \
            grep_http_header_location_quiet) || return

        test "$FILE_URL" || return $ERR_LINK_PASSWORD_REQUIRED

        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0
    fi

    PAGE=$(curl --include -b "$COOKIE_FILE" -b 'LG=en' -d '' \
        --referer "$URL" "$URL") || return

    FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

    if [ -z "$FILE_URL" ]; then
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to 1fichier
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download + del link
1fichier_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r UPLOADURL='https://upload.1fichier.com'
    local LOGIN_DATA S_ID RESPONSE DOWNLOAD_ID REMOVE_ID DOMAIN_ID


    if [ -n "$AUTH" ]; then
        1fichier_login "$AUTH" "$COOKIE_FILE" 'https://1fichier.com' || return
    fi

    S_ID=$(random ll 10)

    # FIXME: See folders later -F 'did=0' /console/get_dirs_for_upload.pl
    RESPONSE=$(curl_with_log -b "$COOKIE_FILE" \
        --form-string "message=$MESSAGE" \
        --form-string "mail=$TOEMAIL" \
        -F "dpass=$LINK_PASSWORD" \
        -F "domain=${DOMAIN:-0}" \
        -F "file[]=@$FILE;filename=$DESTFILE" \
        "$UPLOADURL/upload.cgi?id=$S_ID") || return

    RESPONSE=$(curl --header 'EXPORT:1' -b "$COOKIE_FILE" \
        "$UPLOADURL/end.pl?xid=$S_ID") || return

    # filename;filesize;dlid;rmid,domain;??
    IFS=";" read -r _ _ DOWNLOAD_ID REMOVE_ID DOMAIN_ID _ <<< "$RESPONSE"

    local -a DOMAIN_STR=('1fichier.com' 'alterupload.com' 'cjoint.net' 'desfichiers.com' \
        'dfichiers.com' 'megadl.fr' 'mesfichiers.net' 'piecejointe.net' 'pjointe.com' \
        'tenvoi.com' 'dl4free.com' )

    if [[ $DOMAIN_ID -gt 10 || $DOMAIN_ID -lt 0 ]]; then
        log_error 'Bad domain ID response, maybe API updated?'
        return $ERR_FATAL
    fi

    echo "https://${DOMAIN_STR[$DOMAIN_ID]}/?${DOWNLOAD_ID}"
    echo "https://${DOMAIN_STR[$DOMAIN_ID]}/remove/$DOWNLOAD_ID/$REMOVE_ID"
}

# Delete a file uploaded to 1fichier
# $1: cookie file (unused here)
# $2: delete url
1fichier_delete() {
    local URL=$2
    local PAGE

    if match '/bg/remove/' "$URL"; then
        URL=$(echo "$URL" | replace '/bg/' '/en/')
    elif ! match '/en/remove/' "$URL"; then
        URL=$(echo "$URL" | replace '/remove/' '/en/remove/')
    fi

    PAGE=$(curl "$URL") || return

    # Invalid link - File not found
    if match 'File not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    PAGE=$(curl "$URL" -F 'force=1') || return

    # <div style="width:250px;margin:25px;padding:25px">The file has been destroyed</div>
    if ! match 'file has been' "$PAGE"; then
        log_debug 'unexpected result, site updated?'
        return $ERR_FATAL
    fi
}

# List a 1fichier folder
# $1: 1fichier folder link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
1fichier_list() {
    local URL=$1
    local PAGE LINKS NAMES

    if ! match '/dir/' "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    if match '/../dir/' "$URL"; then
        local BASE_URL DIR_ID
        BASE_URL=$(basename_url "$URL")
        DIR_ID=${URL##*/}
        URL="$BASE_URL/dir/$DIR_ID"
    fi

    PAGE=$(curl -L "$URL") || return
    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'T.l.chargement de' href)
    NAMES=$(echo "$PAGE" | parse_all_tag_quiet 'T.l.chargement de' a)

    test "$LINKS" || return $ERR_LINK_DEAD

    list_submit "$LINKS" "$NAMES" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: 1fichier url
# $3: requested capability list
1fichier_probe() {
    local URL=${2%/}
    local -r REQ_IN=$3
    local FID RESPONSE FILE_NAME FILE_SIZE

    FID=$(parse_quiet . '://\([[:alnum:]]*\)\.' <<< "$URL")
    if [ -n "$FID" ] && [ "$FID" != '1fichier' ]; then
        URL="https://1fichier.com/?$FID"
    fi

    RESPONSE=$(1fichier_checklink "$URL") || return

    # url;filename;filesize
    IFS=';' read -r URL FILE_NAME FILE_SIZE <<< "$RESPONSE"

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        if [[ $FILE_NALE ]]; then
            echo "$FILE_NAME"
            REQ_OUT="${REQ_OUT}f"
        else
            log_debug 'empty filename: file must be private or password protected'
        fi
    fi

    if [[ $REQ_IN = *i* ]]; then
        echo "$FID"
        REQ_OUT="${REQ_OUT}i"
    fi

    if [[ $REQ_IN = *s* ]]; then
        echo "$FILE_SIZE"
        REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *v* ]]; then
        echo "$URL"
        REQ_OUT="${REQ_OUT}v"
    fi

    echo $REQ_OUT
}
