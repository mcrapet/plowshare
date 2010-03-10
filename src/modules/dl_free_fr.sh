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
# Author: StalkR <plowshare@stalkr.net>
#

MODULE_DL_FREE_FR_REGEXP_URL="http://dl.free.fr/"
MODULE_DL_FREE_FR_DOWNLOAD_OPTIONS=""
MODULE_DL_FREE_FR_UPLOAD_OPTIONS=
MODULE_DL_FREE_FR_DOWNLOAD_CONTINUE=yes

# Output a dl.free.fr file download URL (anonymous)
#
# dl_free_fr_download DL_FREE_FR_URL
#
dl_free_fr_download() {
    eval "$(process_options "dl_free_fr" "$MODULE_DL_FREE_FR_DOWNLOAD_OPTIONS" "$@")"

    COOKIES=$(create_tempfile)
    HTML_PAGE=$(curl -L --cookie-jar $COOKIES "$1")

    # Important note: If "free.fr" is your ISP, behavior is different.
    # There is no redirection html page, you can directly wget the URL
    # (Content-Type: application/octet-stream)
    # "curl -I" (http HEAD request) is detected and returns 404 error

    ERR1="erreur 500 - erreur interne du serveur"
    ERR2="erreur 404 - document non trouv."
    if matchi "$ERR1\|$ERR2" "$HTML_PAGE"; then
        log_error "file not found"
        rm -f $COOKIES
        return 254
    fi

    if test "$CHECK_LINK"; then
        rm -f $COOKIES
        return 255
    fi

    FILE_URL=$(echo "$HTML_PAGE" | parse "charger ce fichier" 'href="\([^"].*\)"') ||
        { log_error "Could not parse file URL"; return 1; }

    echo $FILE_URL
    echo
    echo $COOKIES
}
