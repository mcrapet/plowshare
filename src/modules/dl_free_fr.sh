#!/bin/bash
#
# dl.free.fr module
# Copyright (c) 2010-2012 Plowshare team
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
MODULE_DL_FREE_FR_UPLOAD_REMOTE_SUPPORT=no

# Output a dl.free.fr file download URL (anonymous)
# $1: cookie file
# $2: dl.free.fr url
# stdout: real file download link
dl_free_fr_download() {
    eval "$(process_options dl_free_fr "$MODULE_DL_FREE_FR_DOWNLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local URL=$2

    local PAGE FORM_HTML FORM_ACTION FORM_FILE FORM_SUBM SESSID

    # Notes:
    # - "curl -I" (HTTP HEAD request) is ignored (returns 404 error)
    # - Range request is ignored for non Free ISP users (due to redir?)
    PAGE=$(curl -L -i -r 0-1024 "$URL") || return

    # Free is your ISP, this is direct download
    if match '^HTTP/1.1 206' "$PAGE"; then
        test "$CHECK_LINK" && return 0

        echo "$URL"
        return 0
    fi

    local ERR1="erreur 500 - erreur interne du serveur"
    local ERR2="erreur 404 - document non trouv."
    if matchi "$ERR1\|$ERR2" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    FORM_HTML=$(grep_form_by_order "$PAGE" 2) || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_FILE=$(echo "$FORM_HTML" | parse_form_input_by_name 'file' | uri_encode_strict)
    FORM_SUBM=$(echo "$FORM_HTML" | parse_form_input_by_type 'submit' | uri_encode_strict)

    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6Lf-Ws8SAAAAAAO4ND_KCqpZzNZQKYEuOROs4edG'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    PAGE=$(curl -v -c "$COOKIE_FILE" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        -d "file=$FORM_FILE" \
        -d "submit=$FORM_SUBM" \
        -d '_ayl_token_challenge=undefined' \
        -d '_ayl_captcha_engine=recaptcha' \
        -d '_ayl_utf8_ie_fix=%E2%98%83' \
        -d '_ayl_tid=undefined' \
        -d '_ayl_env=prod' \
        --referer "$URL" \
        "http://dl.free.fr/$FORM_ACTION") || return

    SESSID=$(parse_cookie_quiet 'getfile' < "$COOKIE_FILE")
    if [ -z "$SESSID" ]; then
        recaptcha_nack $ID
        return $ERR_CAPTCHA
    fi

    recaptcha_ack $ID
    log_debug "correct captcha"

    echo "$URL"
}

# Upload a file to dl.free.fr
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: dl.free.fr download + del link
dl_free_fr_upload() {
    eval "$(process_options dl_free_fr "$MODULE_DL_FREE_FR_UPLOAD_OPTIONS" "$@")"

    local FILE=$2
    local DESTFILE=$3
    local UPLOADURL='http://dl.free.fr'
    local PAGE FORM ACTION SESSIONID H STATUS MON_PL WAITTIME DL RM

    log_debug "downloading upload page: $UPLOADURL"
    PAGE=$(curl "$UPLOADURL") || return

    FORM=$(grep_form_by_order "$PAGE" 2) || {
        log_error "can't get upload from, website updated?";
        return $ERR_FATAL
    }

    ACTION=$(echo "$FORM" | parse_form_action)
    SESSIONID=$(echo "$ACTION" | cut -d? -f2)
    H=$(create_tempfile) || return

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
        PAGE=$(curl "$MON_PL") || return

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

            echo "$DL"
            echo "$RM"
            return 0
        else
            log_error "unknown state, abort"
            break
        fi

        wait $WAITTIME seconds
    done
    return $ERR_FATAL
}
