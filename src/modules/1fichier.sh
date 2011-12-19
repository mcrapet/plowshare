#!/bin/bash
#
# 1fichier.com module
# Copyright (c) 2011 halfman <Pulpan3@gmail.com>
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

MODULE_1FICHIER_REGEXP_URL="http://\(.*\.\)\?\(1fichier\.\(com\|net\|org\|fr\)\|alterupload\.com\|cjoint\.\(net\|org\)\|desfichiers\.\(com\|net\|org\|fr\)\|dfichiers\.\(com\|net\|org\|fr\)\|megadl\.fr\|mesfichiers\.\(net\|org\)\|piecejointe\.\(net\|org\)\|pjointe\.\(com\|net\|org\|fr\)\|tenvoi\.\(com\|net\|org\)\|dl4free\.com\)/\?$"

MODULE_1FICHIER_DOWNLOAD_OPTIONS=""
MODULE_1FICHIER_DOWNLOAD_RESUME=yes
MODULE_1FICHIER_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_1FICHIER_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account
LINK_PASSWORD,p:,link-password:,PASSWORD,Protect a link with a password
MESSAGE,d:,message:,MESSAGE,Set file message (is send with notification email)
DOMAIN,,domain:,ID,You can set domain ID to upload (ID can be found at http://www.1fichier.com/en/api/web.html)
TOEMAIL,,email-to:,EMAIL,<To> field for notification email"

# Output a 1fichier file download URL
# $1: cookie file
# $2: 1fichier.tld url
# stdout: real file download link
#
# Note: Consecutive HTTP requests must be delayed (>10s).
#       Otherwise you'll get the parallel download message.
1fichier_download() {
    eval "$(process_options 1fichier "$MODULE_1FICHIER_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL="$2"

    PAGE=$(curl -c "$COOKIEFILE" "$URL") || return

    if match "Le fichier demandé n'existe pas." "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    if match "Téléchargements en cours" "$PAGE"; then
        log_error "No parallel download allowed"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr 'Cliquez ici pour' 'href')
    FILENAME=$(echo "$PAGE" | parse_quiet '<title>' '<title>Téléchargement du fichier : *\([^<]*\)')

    echo "$FILE_URL"
    test "$FILENAME" && echo "$FILENAME"

    return 0
}

# Upload a file to 1fichier.tld
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download + del link
1fichier_upload() {
    eval "$(process_options 1fichier "$MODULE_1FICHIER_UPLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local FILE="$2"
    local DESTFILE="$3"
    local UPLOADURL='http://upload.1fichier.com'
    local LOGIN_DATA S_ID RESPONSE DOWNLOAD_ID REMOVE_ID DOMAIN_ID

    detect_javascript || return

    if test "$AUTH"; then
        LOGIN_DATA='mail=$USER&pass=$PASSWORD&submit=Login'
        post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" "https://www.1fichier.com/en/login.pl" >/dev/null || return
    fi

    S_ID=$(echo "var text = ''; var possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'; for(var i=0; i<5; i++) text += possible.charAt(Math.floor(Math.random() * possible.length)); print(text);" | javascript)

    RESPONSE=$(curl_with_log -b "$COOKIEFILE" \
        -F "message=$MESSAGE" \
        -F "mail=$TOEMAIL" \
        -F "dpass=$LINK_PASSWORD" \
        -F "domain=${DOMAIN:-0}" \
        -F "file[]=@$FILE;filename=$DESTFILE" \
        "$UPLOADURL/upload.cgi?id=$S_ID") || return

    RESPONSE=$(curl --header "EXPORT:1" "$UPLOADURL/end.pl?xid=$S_ID" | sed -e 's/;/\n/g')

    DOWNLOAD_ID=$(echo "$RESPONSE" | nth_line 3)
    REMOVE_ID=$(echo "$RESPONSE" | nth_line 4)
    DOMAIN_ID=$(echo "$RESPONSE" | nth_line 5)

    case "$DOMAIN_ID" in
        0)  echo -e "http://$DOWNLOAD_ID.1fichier.com (http://www.1fichier.com/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        1)  echo -e "http://$DOWNLOAD_ID.alterupload.com (http://www.alterupload.com/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        2)  echo -e "http://$DOWNLOAD_ID.cjoint.net (http://www.cjoint.net/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        3)  echo -e "http://$DOWNLOAD_ID.desfichiers.com (http://www.desfichiers.com/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        4)  echo -e "http://$DOWNLOAD_ID.dfichiers.com (http://www.dfichiers.com/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        5)  echo -e "http://$DOWNLOAD_ID.megadl.fr (http://www.megadl.fr/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        6)  echo -e "http://$DOWNLOAD_ID.mesfichiers.net (http://www.mesfichiers.net/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        7)  echo -e "http://$DOWNLOAD_ID.piecejointe.net (http://www.piecejointe.net/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        8)  echo -e "http://$DOWNLOAD_ID.pjointe.com (http://www.pjointe.com/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        9)  echo -e "http://$DOWNLOAD_ID.tenvoi.com (http://www.tenvoi.com/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        10) echo -e "http://$DOWNLOAD_ID.dl4free.com (http://www.dl4free.com/remove/$DOWNLOAD_ID/$REMOVE_ID)"
            ;;
        *)  log_error "Bad domain ID response, maybe API updated?"
            return $ERR_FATAL
            ;;
    esac
    return 0
}
