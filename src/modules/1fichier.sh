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
# Author: halfman <Pulpan3@gmail.com>

MODULE_1FICHIER_REGEXP_URL="http://\(.*\.\)\?\(1fichier\.\(com\|net\|org\|fr\)\|alterupload\.com\|cjoint\.\(net\|org\)\|desfichiers\.\(com\|net\|org\|fr\)\|dfichiers\.\(com\|net\|org\|fr\)\|megadl\.fr\|mesfichiers\.\(net\|org\)\|piecejointe\.\(net\|org\)\|pjointe\.\(com\|net\|org\|fr\)\|tenvoi\.\(com\|net\|org\)\|dl4free\.com\)/"
MODULE_1FICHIER_DOWNLOAD_OPTIONS=""
MODULE_1FICHIER_DOWNLOAD_CONTINUE=yes

# Output a 1fichier file download URL
# $1: 1FICHIER_URL
# stdout: real file download link
1fichier_download() {
    set -e
    eval "$(process_options 1fichier "$MODULE_1FICHIER_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    COOKIES=$(create_tempfile)

    PAGE=$(curl -c "$COOKIES" "$URL")

    if match "Le fichier demandé n'existe pas." "$PAGE"; then
        log_error "File not found."
        rm -f $COOKIES
        return 254
    fi

    test "$CHECK_LINK" && return 255

    FILE_URL=$(echo "$PAGE" | parse_attr 'Cliquez ici pour' 'href')
    FILENAME=$(echo "$PAGE" | parse_quiet '<title>' '<title>Téléchargement du fichier : *\([^<]*\)')

    echo "$FILE_URL"
    test "$FILENAME" && echo "$FILENAME"
    echo "$COOKIES"

    return 0
}
