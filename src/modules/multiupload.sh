# Plowshare multiupload.nl module
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

MODULE_MULTIUPLOAD_REGEXP_URL='http://\(www\.\)\?multiupload\.\(com\|nl\)/'

MODULE_MULTIUPLOAD_DOWNLOAD_OPTIONS=""
MODULE_MULTIUPLOAD_DOWNLOAD_RESUME=no
MODULE_MULTIUPLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_MULTIUPLOAD_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_MULTIUPLOAD_UPLOAD_OPTIONS="
COUNT,,count,n=COUNT,Take COUNT mirrors (hosters) from the available list. Default is 9.
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
FROMEMAIL,,email-from,e=EMAIL,<From> field for notification email
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_MULTIUPLOAD_UPLOAD_REMOTE_SUPPORT=no

MODULE_MULTIUPLOAD_LIST_OPTIONS=""
MODULE_MULTIUPLOAD_LIST_HAS_SUBFOLDERS=no

# Output a multiupload.nl "direct download" link
# $1: cookie file (unused here)
# $2: multiupload url
# stdout: real file download link
multiupload_download() {
    local -r URL=$2
    local PAGE FID JSON FILE_URL

    PAGE=$(curl -L "$URL" | break_html_lines_alt) || return

    # Unfortunately, the link you have clicked is not available.
    if match 'is not available' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # <div id="downloadbutton_" style="">
    FILE_URL=$(parse_attr_quiet 'id=.dlbutton' href <<< "$PAGE")

    if [ -z "$FILE_URL" ]; then
        log_error 'Direct download link not available'
        return $ERR_FATAL
    fi

    echo "$FILE_URL"
}

# Upload a file to multiupload.nl
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: multiupload.nl download link
multiupload_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://multiupload.nl'
    local PAGE FORM_HTML FORM_ACTION FORM_U FORM_UID DLID SERVICES LINE N FORM_FIELDS

    PAGE=$(curl "$BASE_URL" | break_html_lines_alt) || return

    FORM_HTML=$(grep_form_by_id "$PAGE" uploadfrm) || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_U=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'u')
    FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'UPLOAD_IDENTIFIER')

    # List:
    # service_1 : MU (Megaupload)
    # service_5 : RS (Rapidshare)
    # service_6 : ZS (Zshare)
    # service_7 : DF (DepositFiles)
    # service_9 : HF (HotFile)
    # service_10 : UP (Uploading.com)
    # service_11 : 2S (2Shared.com)
    # service_14 : FS (FileServe)
    # service_15 : FC (FileSonic)
    # service_16 : UK (UploadKing)
    # service_17 : UH (UploadHere)
    # service_18 : WU (Wupload)
    # service_19 : PL (PutLocker)
    # service_20 : OR (Oron)
    # service_21 : FF (FileFactory)
    # service_23 : FS (FreakShare)
    # service_24 : TB (TurboBit)
    # service_25 : UB (UploadBoost)
    # service_26 : BF (Bayfiles)
    # service_29 : BS (Bitshare)
    # service_30 : CO (Crocko)
    # service_31 : UB (Uptobox)
    # service_34 : UI (UppIt)
    # service_35 : FR (FileRIO)
    # service_36 : FS (FileSwap)
    #
    # Changes:
    # - 2011.09.12: MU, UK, DF, UH, HF, UP
    # - 2011.10.29: MU, UK, DF, HF, UH, ZS, FC, FS, WU
    # - 2012.05.25: DF, 2S, PL, OR, FF, FS, TB, UB, BF
    # - 2013.10.01: DF, PL, TB, BS, CO, UB, UI, FR, FS

    FORM_FIELDS=''

    if [ -n "$COUNT" ]; then
        if (( COUNT > 9 )); then
            COUNT=9
            log_error "Too big integer value for --count, set it to $COUNT"
        fi

        SERVICES=$(echo "$FORM_HTML" | parse_all_attr '=.sradio_[[:digit:]]\+' name) || return
        while read -r LINE; do
            (( COUNT-- > 0 )) || break
            N=$(echo "$LINE" | parse_quiet . '^service_\([[:digit:]]\+\)')
            if [ -n "$N" ]; then
                FORM_FIELDS="$FORM_FIELDS -F service_$N=1 -F username_$N= -F password_$N= -F remember_$N="
            fi
        done <<< "$SERVICES"
    else
        # Keep default settings
        SERVICES=$(echo "$FORM_HTML" | parse_all_attr 'checked>' name) || return
        while read -r LINE; do
            N=$(echo "$LINE" | parse_quiet . '^service_\([[:digit:]]\+\)')
            if [ -n "$N" ]; then
                FORM_FIELDS="$FORM_FIELDS -F service_$N=1 -F username_$N= -F password_$N= -F remember_$N="
            fi
        done <<< "$SERVICES"
    fi

    # Notes:
    # - file0 can go up to file9 (included)
    # - fetchfield0 & fetchdesc0 can go up to 9 (not used here)
    PAGE=$(curl_with_log \
        --form-string "toemail=$TOEMAIL" \
        --form-string "fromemail=$FROMEMAIL" \
        --form-string "description_0=$DESCRIPTION" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        -F "UPLOAD_IDENTIFIER=$FORM_UID" \
        $FORM_FIELDS \
        -F "u=$FORM_U" "$FORM_ACTION") || return

    DLID=$(echo "$PAGE" | parse_json downloadid) || return

    echo "$BASE_URL/$DLID"
}

# List links from a multiupload link
# Note: multiupload direct link is not printed
# $1: multiupload link
# $2: recurse subfolders (ignored here)
# stdout: list of links
multiupload_list() {
    local URL=$1
    local PAGE LINKS FILE_NAME SITE_URL

    PAGE=$(curl -L "$URL" | break_html_lines_alt) || return

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet '"urlhref' href)
    if [ -z "$LINKS" ]; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(echo "$PAGE" | parse '#666666;' '^\(.*\)[[:space:]]<font')

    #  Print links (stdout)
    while read SITE_URL; do
        test "$SITE_URL" || continue
        URL=$(curl --head "$SITE_URL" | grep_http_header_location_quiet) || continue
        if [ -n "$URL" ]; then
            echo "$URL"
            echo "$FILE_NAME"
        fi
    done <<< "$LINKS"
}
