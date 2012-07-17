#!/bin/bash
#
# 1fichier.com module
# Copyright (c) 2011 halfman <Pulpan3@gmail.com>
# Copyright (c) 2012 Plowshare team
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

MODULE_1FICHIER_REGEXP_URL="http://\(.*\.\)\?\(1fichier\.\(com\|net\|org\|fr\)\|alterupload\.com\|cjoint\.\(net\|org\)\|desfichiers\.\(com\|net\|org\|fr\)\|dfichiers\.\(com\|net\|org\|fr\)\|megadl\.fr\|mesfichiers\.\(net\|org\)\|piecejointe\.\(net\|org\)\|pjointe\.\(com\|net\|org\|fr\)\|tenvoi\.\(com\|net\|org\)\|dl4free\.com\)/\?"

MODULE_1FICHIER_DOWNLOAD_OPTIONS=""
MODULE_1FICHIER_DOWNLOAD_RESUME=yes
MODULE_1FICHIER_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_1FICHIER_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
MESSAGE,d,message,S=MESSAGE,Set file message (is send with notification email)
DOMAIN,,domain,N=ID,You can set domain ID to upload (ID can be found at http://www.1fichier.com/en/api/web.html)
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_1FICHIER_UPLOAD_REMOTE_SUPPORT=no

MODULE_1FICHIER_DELETE_OPTIONS=""

# Output a 1fichier file download URL
# $1: cookie file
# $2: 1fichier.tld url
# stdout: real file download link
#
# Note: Consecutive HTTP requests must be delayed (>10s).
#       Otherwise you'll get the parallel download message.
1fichier_download() {
    local COOKIEFILE=$1
    local URL=$2
    local PAGE FILE_URL FILENAME

    PAGE=$(curl -c "$COOKIEFILE" "$URL") || return

    # Location: http://www.1fichier.com/?c=SCAN
    if match 'MOVED - TEMPORARY_REDIRECT' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match "Le fichier demandé n'existe pas." "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # notice typo in 'telechargement'
    if match "entre 2 télécharger\?ments" "$PAGE"; then
        log_error "No parallel download allowed"
        return $ERR_LINK_TEMP_UNAVAILABLE
    # Please wait until the file has been scanned by our anti-virus
    elif match 'Please wait until the file has been scanned' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Adyoulike (advertising) Captcha..
    # Important: It is currenly disabled...
    FILE_URL=$(curl -i -b "$COOKIEFILE" \
        -d '_ayl_captcha_engine=adyoulike' \
        -d '_ayl_response=' \
        -d '_ayl_utf8_ie_fix=%E2%98%83' \
        -d '_ayl_env=prod' \
        -d '_ayl_token_challenge=VxuaYvYGUvk9npNIV6BKr3n4TNh%7EMjA4' \
        -d '_ayl_tid=ABEIAuodCEKHRD30ntA6dojxuYaCfgd1' \
        "$URL" | grep_http_header_location_quiet) || return

    if [ -z "$FILE_URL" ]; then
        log_error "Wrong captcha"
        return $ERR_CAPTCHA
    fi

    FILENAME=$(echo "$PAGE" | parse_quiet '<title>' '<title>Téléchargement du fichier : *\([^<]*\)')

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to 1fichier.tld
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download + del link
1fichier_upload() {
    local COOKIEFILE=$1
    local FILE=$2
    local DESTFILE=$3
    local UPLOADURL='http://upload.1fichier.com'
    local LOGIN_DATA S_ID RESPONSE DOWNLOAD_ID REMOVE_ID DOMAIN_ID

    if test "$AUTH"; then
        LOGIN_DATA='mail=$USER&pass=$PASSWORD&submit=Login'
        post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" "https://www.1fichier.com/en/login.pl" >/dev/null || return
    fi

    # Initial js code:
    # var text = ''; var possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    # for(var i=0; i<5; i++) text += possible.charAt(Math.floor(Math.random() * possible.length)); print(text);
    S_ID=$(random ll 5)

    RESPONSE=$(curl_with_log -b "$COOKIEFILE" \
        --form-string "message=$MESSAGE" \
        --form-string "mail=$TOEMAIL" \
        -F "dpass=$LINK_PASSWORD" \
        -F "domain=${DOMAIN:-0}" \
        -F "file[]=@$FILE;filename=$DESTFILE" \
        "$UPLOADURL/upload.cgi?id=$S_ID") || return

    RESPONSE=$(curl --header "EXPORT:1" "$UPLOADURL/end.pl?xid=$S_ID" | sed -e 's/;/\n/g')

    DOWNLOAD_ID=$(echo "$RESPONSE" | nth_line 3)
    REMOVE_ID=$(echo "$RESPONSE" | nth_line 4)
    DOMAIN_ID=$(echo "$RESPONSE" | nth_line 5)

    local -a DOMAIN_STR=('1fichier.com' 'alterupload.com' 'cjoint.net' 'desfichiers.com' \
        'dfichiers.com' 'megadl.fr' 'mesfichiers.net' 'piecejointe.net' 'pjointe.com' \
        'tenvoi.com' 'dl4free.com' )

    if [[ $DOMAIN_ID -gt 10 || $DOMAIN_ID -lt 0 ]]; then
        log_error "Bad domain ID response, maybe API updated?"
        return $ERR_FATAL
    fi

    echo "http://${DOWNLOAD_ID}.${DOMAIN_STR[$DOMAIN_ID]}"
    echo "http://www.${DOMAIN_STR[$DOMAIN_ID]}/remove/$DOWNLOAD_ID/$REMOVE_ID"
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

    PAGE=$(curl "$URL" -F "force=1") || return

    # <div style="width:250px;margin:25px;padding:25px">The file has been destroyed</div>
    if ! match 'file has been' "$PAGE"; then
        log_debug "unexpected result, site updated?"
        return $ERR_FATAL
    fi
}
