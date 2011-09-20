#!/bin/bash
#
# dl.free.fr module
# Copyright (c) 2010-2011 Plowshare team
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

MODULE_DL_FREE_FR_REGEXP_URL="http://dl.free.fr/"

MODULE_DL_FREE_FR_DOWNLOAD_OPTIONS=""
MODULE_DL_FREE_FR_DOWNLOAD_RESUME=yes
MODULE_DL_FREE_FR_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes

MODULE_DL_FREE_FR_UPLOAD_OPTIONS=""

# Output a dl.free.fr file download URL (anonymous)
# $1: cookie file
# $2: dl.free.fr url
# stdout: real file download link
dl_free_fr_download() {
    local COOKIEFILE="$1"
    local HTML_PAGE=$(curl -L --cookie-jar $COOKIEFILE "$2")

    # Important note: If "free.fr" is your ISP, behavior is different.
    # There is no redirection html page, you can directly wget the URL
    # (Content-Type: application/octet-stream)
    # "curl -I" (http HEAD request) is detected and returns 404 error

    local ERR1="erreur 500 - erreur interne du serveur"
    local ERR2="erreur 404 - document non trouv."
    if matchi "$ERR1\|$ERR2" "$HTML_PAGE"; then
        log_error "file not found"
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    FILE_URL=$(echo "$HTML_PAGE" | parse "charger ce fichier" 'href="\([^"].*\)"') ||
        { log_error "Could not parse file URL"; return 1; }

    echo $FILE_URL
}
 
# Upload a file to dl.free.fr
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: dl.free.fr download + del link
dl_free_fr_upload() {
    eval "$(process_options dl_free_fr "$MODULE_DL_FREE_FR_UPLOAD_OPTIONS" "$@")"

    local FILE="$2"
    local DESTFILE="$3"
    local UPLOADURL="http://dl.free.fr"

    log_debug "downloading upload page: $UPLOADURL"
    PAGE=$(curl "$UPLOADURL")

    local FORM=$(grep_form_by_order "$PAGE" 2) || {
        log_error "can't get upload from, website updated?";
        return 1;
    }

    ACTION=$(echo "$FORM" | parse_form_action)
    SESSIONID=$(echo "$ACTION" | cut -d? -f2)
    H=$(create_tempfile)

    # <input> markers are: ufile, mail1, mail2, mail3, mail4, message, password
    # Returns 302. Answer headers are not returned with -i switch, I must
    # use -D. This should be reported to cURL bug tracker.
    log_debug "starting file upload: $FILE"
    STATUS=$(curl_with_log -D $H --referer "$UPLOADURL/index_nojs.pl" \
        -F "ufile=@$FILE;filename=$DESTFILE" \
        -F "mail1=" \
        -F "mail2=" \
        -F "mail3=" \
        -F "mail4=" \
        -F "message=test" \
        -F "password=" \
        "$UPLOADURL$ACTION")

    MON_PL=$(cat "$H" | grep_http_header_location)
    rm -f "$H"

    log_debug "Monitoring page: $MON_PL"

    WAITTIME=5
    while [ $WAITTIME -lt 320 ] ; do
        PAGE=$(curl "$MON_PL")

        if match 'En attente de traitement...' "$PAGE"; then
            log_debug "please wait"
            ((WAITTIME += 4))
        elif match 'Test antivirus...' "$PAGE"; then
            log_debug "antivirus test"
            WAITTIME=3
        elif match 'Mise en ligne du fichier...' "$PAGE"; then
            log_debug "nearly online!"
            WAITTIME=2
        elif match 'Erreur de traitement...' "$PAGE"; then
            log_error "process failed, you may try again"
            break
        # Fichier "foo" en ligne, procédure terminée avec succès...
        elif match 'Le fichier sera accessible' "$PAGE"; then
            DL=$(echo "$PAGE" | parse 'en ligne' \
                    "window\.open('\(http:\/\/dl.free.fr\/[^?]*\)')" | html_to_utf8)
            RM=$(echo "$PAGE" | parse 'en ligne' \
                    "window\.open('\(http:\/\/dl.free.fr\/rm\.pl[^']*\)" | html_to_utf8)
            echo "$DL ($RM)"
            return 0
        else
            log_error "unknown state, abort"
            break
        fi

        wait $WAITTIME seconds
    done
    return 1
}
