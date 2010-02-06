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
# dl.free.fr module for plowshare
# Author StalkR <plowshare@stalkr.net>
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
    DATA=$(curl -L --cookie-jar $COOKIES "$1")

    if match "Fichier inexistant" "$DATA"; then
        error "file not found"
        rm -f $COOKIES
        return 254
    fi
    
    if test "$CHECK_LINK"; then
        rm -f $COOKIES
        return 255
    fi
    
    FILE_URL=$(echo "$DATA" | parse "charger ce fichier" 'href="\([^"].*\)"') ||
        { error "Could not parse file URL"; return 1; } 

    echo $FILE_URL
    echo
    echo $COOKIES
}
