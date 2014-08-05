# Plowshare dataport.cz module
# Copyright (c) 2011 halfman <Pulpan3@gmail.com>
# Copyright (c) 2012-2013 Plowshare team
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

MODULE_DATAPORT_CZ_REGEXP_URL='http://\(www\.\)\?dataport\.cz/'

MODULE_DATAPORT_CZ_DOWNLOAD_OPTIONS=""
MODULE_DATAPORT_CZ_DOWNLOAD_RESUME=yes
MODULE_DATAPORT_CZ_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_DATAPORT_CZ_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_DATAPORT_CZ_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_DATAPORT_CZ_UPLOAD_REMOTE_SUPPORT=no

MODULE_DATAPORT_CZ_DELETE_OPTIONS=""

# Static function. Proceed with login (free or premium)
dataport_cz_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT

    LOGIN_DATA='username=$USER&password=$PASSWORD&loginFormSubmit='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/?do=loginForm-submit" -L) || return

    # <a href="/user/register">Registrace</a>&nbsp;
    if match '/user/register' "$LOGIN_RESULT"; then
        return $ERR_LOGIN_FAILED
    fi

    # If successful, cookie entry PHPSESSID is updated
}

# Output a dataport.cz file download URL
# $1: cookie file
# $2: dataport.cz url
# stdout: real file download link
dataport_cz_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(uri_encode_file "$2")
    local -r BASE_URL='http://www.dataport.cz'
    local PAGE CAPTCHA_URL CAPTCHA_IMG FILE_URL FILE_NAME WAIT_TIME
    local FORM_HTML FORM_URL FORM_FILE_ID FORM_CAPTCHA_ID FORM_CHECK

    PAGE=$(curl --location -c "$COOKIE_FILE" "$URL") || return

    # <h2>Nahrát soubor <span class="h2sub">(max. 2GB / soubor)</span></h2>
    if match '<h2>Nahrát soubor <' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_id "$PAGE" 'free_download_form') || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_FILE_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'fileId') || return
    FORM_CAPTCHA_ID=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'captchaId')
    FORM_CHECK=$(echo "$FORM_HTML" | parse_form_input_by_name 'check') || return

    FILE_NAME=$(parse_tag 'itemprop=.name' span <<< "$PAGE")

    CAPTCHA_URL=$(parse_attr '/captcha/' 'src' <<< "$PAGE") || return
    CAPTCHA_IMG=$(create_tempfile '.png') || return

    # Get new image captcha (cookie is mandatory)
    curl -b "$COOKIE_FILE" -o "$CAPTCHA_IMG" "$BASE_URL$CAPTCHA_URL" || return

    # Počet volných slotů: <span class="darkblue">1</span><br />
    WAIT_TIME=$(parse_tag 'volných slotů' span <<< "$PAGE") || return
    wait $((WAIT_TIME + 1)) || return

    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG") || return
    { read WORD; read ID; } <<<"$WI"
    rm -f "$CAPTCHA_IMG"

    PAGE=$(curl -b "$COOKIE_FILE" -d 'freeDownloadFormSubmit=' \
        -d "captchaCode=$WORD" \
        -d "fileId=$FORM_FILE_ID" \
        -d "captchaId=$FORM_CAPTCHA_ID" \
        -d "check=$FORM_CHECK" "$BASE_URL$FORM_URL") || return

    FILE_URL=$(parse_attr '<a' href <<< "$PAGE" | \
        replace_all '&amp;' '&') || return

    if match 'ticketId=' "$FILE_URL"; then
        captcha_ack $ID
        log_debug 'Correct captcha'

        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0

    else
        PAGE=$(curl -b "$COOKIE_FILE" "$FILE_URL") || return

        # Captcha can be good or not ..
        #  Je nám líto, ale momentálně nejsou k dispozici žádné free download sloty, zkuste to později nebo si kupte premium
        if match 'ale momentálně nejsou k dispozici' "$PAGE"; then
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        # Špatně opsaný kód z obrázu
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi
}

# Upload a file to dataport.cz
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
dataport_cz_upload() {
    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://dataport.cz'
    local IURL PAGE FORM_ACTION FORM_SUBMIT DL_LINK DEL_LINK

    if test "$AUTH"; then
        dataport_cz_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$BASE_URL") || return

    IURL=$(echo "$PAGE" | parse_attr '<iframe' 'src') || return
    PAGE=$(curl -L -b "$COOKIE_FILE" "$IURL") || return

    FORM_ACTION=$(echo "$PAGE" | parse_form_action | replace_all '&amp;' '&') || return
    FORM_SUBMIT=$(echo "$PAGE" | parse_form_input_by_name 'uploadFormSubmit') || return

    PAGE=$(curl_with_log -L -b "$COOKIE_FILE" -e "$IURL" \
        -F "file=@$FILE;filename=$DESTFILE" \
        -F "uploadFormSubmit=$FORM_SUBMIT" \
        -F "description=None" \
        "$(basename_url "$IURL")$FORM_ACTION") || return

    DL_LINK=$(echo "$PAGE" | parse_attr '/file/' value) || return
    DEL_LINK=$(echo "$PAGE" | parse_attr delete value)

    echo "$DL_LINK"
    echo "$DEL_LINK"
}

# Delete a file on dataport.cz
# $1: cookie file (unused here)
# $2: download link
dataport_cz_delete() {
    local URL=$2
    local PAGE

    PAGE=$(curl -L -I "$URL" | grep_http_header_location) || return

    if [ "$PAGE" = 'http://dataport.cz/' ]; then
        return $ERR_FATAL
    fi
}

# urlencode only the file part by splitting with last slash
uri_encode_file() {
    echo "${1%/*}/$(echo "${1##*/}" | uri_encode_strict)"
}
