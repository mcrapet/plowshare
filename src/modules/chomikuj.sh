# Plowshare chomikuj.pl module
# Copyright (c) 2013 Plowshare team
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

MODULE_CHOMIKUJ_REGEXP_URL='http://\(www\.\)\?chomikuj\.pl/'

MODULE_CHOMIKUJ_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (used to download private files)"
MODULE_CHOMIKUJ_DOWNLOAD_RESUME=yes
MODULE_CHOMIKUJ_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_CHOMIKUJ_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_CHOMIKUJ_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
FOLDER,,folder,s=FOLDER,Folder to upload files into
DESCRIPTION,d,description,S=DESCRIPTION,Set file description"
MODULE_CHOMIKUJ_UPLOAD_REMOTE_SUPPORT=no

MODULE_CHOMIKUJ_LIST_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected folders"
MODULE_CHOMIKUJ_LIST_HAS_SUBFOLDERS=yes

MODULE_CHOMIKUJ_PROBE_OPTIONS=""

# Static function. Proceed with login.
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: token
#         user id
chomikuj_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local PAGE VERIF_TOKEN USER_ID LOGIN_DATA LOGIN_RESULT

    PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL/") || return

    VERIF_TOKEN=$(parse_form_input_by_name '__RequestVerificationToken' <<< "$PAGE") || return

    LOGIN_DATA="ReturnUrl=&Login=\$USER&Password=\$PASSWORD&rememberLogin=false&__RequestVerificationToken=$VERIF_TOKEN"
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/action/Login/TopBarLogin" \
        -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest') || return

    if match '"IsSuccess":false' "$LOGIN_RESULT" ||
        ! match '"Type":"Redirect"' "$LOGIN_RESULT"; then
        return $ERR_LOGIN_FAILED
    fi

    REDIRECT=$(parse_json 'redirectUrl' <<< "$LOGIN_RESULT") || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL$REDIRECT") || return

    VERIF_TOKEN=$(parse_form_input_by_name '__RequestVerificationToken' <<< "$PAGE") || return

    USER_ID=$(parse_form_input_by_name 'chomikId' <<< "$PAGE") || return

    echo "$VERIF_TOKEN"
    echo "$USER_ID"
}

# Check if specified folder name is valid.
# Cannot be two folders with the same name in root.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base URL
# $4: user data (token and user id)
# stdout: folder ID
chomikuj_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local -r USER_DATA=$4

    local PAGE VERIF_TOKEN USER_ID FOLDERS FOLDER_ID

    { read VERIF_TOKEN; read USER_ID; } <<<"$USER_DATA"

    PAGE=$(curl -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d 'FolderId=0' \
        -d "ChomikId=$USER_ID" \
        --data-urlencode "__RequestVerificationToken=$VERIF_TOKEN" \
        "$BASE_URL/action/tree/loadtree") || return
    PAGE=$(replace_all '<td>' $'\n<td>' <<< "$PAGE") || return

    FOLDERS=$(parse_all_attr 'id="Ta_' 'title' <<< "$PAGE") || return

    if ! match "^$NAME$" "$FOLDERS"; then
        log_debug 'Creating folder.'

        PAGE=$(curl -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d 'FolderId=0' \
            -d "ChomikId=$USER_ID" \
            -d "FolderName=$NAME" \
            -d 'AdultContent=false' \
            -d 'Password=' \
            --data-urlencode "__RequestVerificationToken=$VERIF_TOKEN" \
            "$BASE_URL/action/FolderOptions/NewFolderAction") || return

        if ! match '"IsSuccess":true' "$PAGE"; then
            log_error "Could not create folder."
            return $ERR_FATAL
        fi

        PAGE=$(curl -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d 'FolderId=0' \
            -d "ChomikId=$USER_ID" \
            --data-urlencode "__RequestVerificationToken=$VERIF_TOKEN" \
            "$BASE_URL/action/tree/loadtree") || return
        PAGE=$(replace_all '<td>' $'\n<td>' <<< "$PAGE") || return

        FOLDERS=$(parse_all_attr 'id="Ta_' 'title' <<< "$PAGE") || return

        if ! match "^$NAME$" "$FOLDERS"; then
            log_error 'Could not create folder.'
            return $ERR_FATAL
        fi
    fi

    FOLDER_ID=$(parse_attr "title=\"$NAME\" id=\"Ta_" 'rel' <<< "$PAGE") || return

    log_debug "Folder ID: '$FOLDER_ID'"

    echo "$FOLDER_ID"
}

# Output a chomikuj.pl file download URL
# $1: cookie file
# $2: chomikuj.pl url
# stdout: real file download link
chomikuj_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(replace '://www.' '://' <<< "$2")
    local -r BASE_URL='http://chomikuj.pl'

    local PAGE VERIF_TOKEN FILE_ID FILE_URL FILENAME

    if [ -n "$AUTH" ]; then
        chomikuj_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" >/dev/null || return
    fi

    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    if [ -n "$LOCATION" ] || \
        match '404 Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    PAGE=$(replace_all '<input' $'\n<input' <<< "$PAGE")

    VERIF_TOKEN=$(parse_form_input_by_name '__RequestVerificationToken' <<< "$PAGE") || return

    FILE_ID=$(parse_form_input_by_name 'FileId' <<< "$PAGE") || return

    FILENAME=$(parse_tag 'Download:' 'b' <<< "$PAGE") || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d "fileId=$FILE_ID" \
        --data-urlencode "__RequestVerificationToken=$VERIF_TOKEN" \
        "$BASE_URL/action/License/Download") || return

	if match 'Pobranie pliku o rozmiarze powyżej 1 MB' "$PAGE"; then
        log_error 'Traffic limit reached.'
        return $ERR_LINK_NEED_PERMISSIONS
	fi

    FILE_URL=$(parse_json 'redirectUrl' <<< "$PAGE") || return
    # For backward compatibility, old versions of echo cannot convert \uXXXX
    FILE_URL=$(replace_all '\u0026' '&' <<< "$FILE_URL")
    #FILE_URL=$(echo -e "$FILE_URL")

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to chomikuj.pl
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
chomikuj_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://chomikuj.pl'

    local PAGE USER_DATA VERIF_TOKEN USER_ID UP_URL FILE_ID LINK_DL FILE_NAME

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    USER_DATA=$(chomikuj_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    { read VERIF_TOKEN; read USER_ID; } <<<"$USER_DATA"

    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(chomikuj_check_folder "$FOLDER" "$COOKIE_FILE" "$BASE_URL" "$USER_DATA") || return
    else
        FOLDER_ID="0"
    fi

    PAGE=$(curl -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d "accountid=$USER_ID" \
        -d "folderid=$FOLDER_ID" \
        --data-urlencode "__RequestVerificationToken=$VERIF_TOKEN" \
        "$BASE_URL/action/Upload/GetUrl/") || return

    UP_URL=$(parse_json 'Url' <<< "$PAGE") || return
    UP_URL=$(replace_all '\u0026' '&' <<< "$UP_URL")
    #UP_URL=$(echo -e "$UP_URL")

    PAGE=$(curl_with_log \
        -F "files[]=@$FILE;filename=$DEST_FILE" \
        "$UP_URL") || return

    if ! match '"url"' "$PAGE"; then
        log_error 'Upload failed.'
        return $ERR_FATAL
    else
        FILE_ID=$(parse_json 'fileId' <<< "$PAGE") || return
        LINK_DL=$(parse_json 'url' <<< "$PAGE") || return
        LINK_DL="$BASE_URL$LINK_DL"
    fi

    if [ -n "$DESCRIPTION" ]; then
        PAGE=$(curl -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d "chomikId=$USER_ID" \
            -d "folderId=$FOLDER_ID" \
            -d "fileId=$FILE_ID" \
            --data-urlencode "__RequestVerificationToken=$VERIF_TOKEN" \
            "$BASE_URL/action/FileDetails/editNameAndDesc") || return

        PAGE=$(parse_json 'Content' <<< "$PAGE") || return
        PAGE=$(echo -e "$PAGE")
		FILE_NAME=$(parse_attr 'id="Name"' 'value' <<< "$PAGE") || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d "FileId=$FILE_ID" \
            -d "Name=$FILE_NAME" \
            -d "Description=$DESCRIPTION" \
            --data-urlencode "__RequestVerificationToken=$VERIF_TOKEN" \
            "$BASE_URL/action/FileDetails/EditNameAndDescAction") || return

        if ! match '"IsSuccess":true,"Data":{"Status":"OK"}' "$PAGE"; then
            log_error 'Could not set description.'
        fi
    fi

    echo "$LINK_DL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: chomikuj.pl url
# $3: requested capability list
# stdout: 1 capability per line
chomikuj_probe() {
    local -r URL=$(replace '://www.' '://' <<< "$2")
    local -r REQ_IN=$3

    local PAGE FILE_URL FILE_SIZE REQ_OUT

    PAGE=$(curl -i "$URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    if [ -n "$LOCATION" ] || \
        match '404 Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'Download:' 'b' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag 'fileSize' 'p' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a chomikuj.pl web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
chomikuj_list() {
    local -r URL=$(replace '://www.' '://' <<< "$1")
    local -r REC=$2
    local -r BASE_URL='http://chomikuj.pl'

    local PAGE LOCATION LINKS NAMES PAGES_BAR LAST_PAGE PAGE_NUMBER COOKIE_FILE

    PAGE=$(curl -i "$URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    if [ -n "$LOCATION" ] || \
        match '404 Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    if match 'LoginToFolder' "$PAGE"; then
        log_debug 'Password protected folder.'

        [ -z "$LINK_PASSWORD" ] && return $ERR_LINK_PASSWORD_REQUIRED

        local FORM_HTML FORM_CHOMIK_ID FORM_FOLDER_ID FORM_FOLDER_NAME FORM_REMEMBER
        FORM_HTML=$(grep_form_by_id "$PAGE" 'LoginToFolder') || return
        FORM_CHOMIK_ID=$(parse_form_input_by_name 'ChomikId' <<< "$FORM_HTML") || return
        FORM_FOLDER_ID=$(parse_form_input_by_name 'FolderId' <<< "$FORM_HTML") || return
        FORM_FOLDER_NAME=$(parse_form_input_by_name 'FolderName' <<< "$FORM_HTML") || return

        COOKIE_FILE=$(create_tempfile) || return

        PAGE=$(curl -c "$COOKIE_FILE" \
            -H 'X-Requested-With: XMLHttpRequest' \
            -d "ChomikId=$FORM_CHOMIK_ID" \
            -d "FolderId=$FORM_FOLDER_ID" \
            -d "FolderName=$FORM_FOLDER_NAME" \
            -d "Password=$LINK_PASSWORD" \
            -d 'Remember=true' \
            "$BASE_URL/action/Files/LoginToFolder") || return

        if ! match '"IsSuccess":true' "$PAGE"; then
            rm -f "$COOKIE_FILE"
            return $ERR_LINK_PASSWORD_REQUIRED
        fi

        PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return
    fi

    if match '<a class="downloadAction"' "$PAGE"; then
        LINKS=$(parse_all_quiet '<a class="downloadAction"' '\(href="[^"]\+\)' <<< "$PAGE")
        NAMES=$(parse_all_quiet '<a class="downloadAction"' '<span class="bold">\(.*\)</a>' <<< "$PAGE")
    else
        LINKS=$(parse_all_quiet 'expanderHeader downloadAction' '\(href="[^"]\+\)' <<< "$PAGE")
        NAMES=$(parse_all_quiet 'expanderHeader downloadAction' '<span class="bold">\(.*\)$' 1 <<< "$PAGE")
    fi

    PAGES_BAR=$(parse_quiet 'paginator' '<div class="paginator[^>]*>\(.*\)$' <<< "$PAGE")
    PAGES_BAR=$(break_html_lines_alt <<< "$PAGES_BAR")
    PAGES_BAR=$(parse_all_attr_quiet 'title' <<< "$PAGES_BAR")

    LAST_PAGE=$(last_line <<< "$PAGES_BAR")

    if [ "$LAST_PAGE" = '9 ...' ]; then
        PAGE=$(curl -b "$COOKIE_FILE" -i "$URL,9999999") || return
        LOCATION=$(grep_http_header_location <<< "$PAGE") || return
        LAST_PAGE=$(parse . ',\([0-9]\+\)$' <<< "$LOCATION") || return
    fi

    if [ -n "$LAST_PAGE" ];then
        for (( PAGE_NUMBER=2; PAGE_NUMBER<=LAST_PAGE; PAGE_NUMBER++ )); do
            log_debug "Listing page #$PAGE_NUMBER"

            PAGE=$(curl -b "$COOKIE_FILE" "$URL,$PAGE_NUMBER") || return

            if match '<a class="downloadAction"' "$PAGE"; then
                LINKS=$LINKS$'\n'$(parse_all_quiet '<a class="downloadAction"' '\(href="[^"]\+\)' <<< "$PAGE")
                NAMES=$NAMES$'\n'$(parse_all_quiet '<a class="downloadAction"' '<span class="bold">\(.*\)</a>' <<< "$PAGE")
            else
                LINKS=$LINKS$'\n'$(parse_all_quiet 'expanderHeader downloadAction' '\(href="[^"]\+\)' <<< "$PAGE")
                NAMES=$NAMES$'\n'$(parse_all_quiet 'expanderHeader downloadAction' '<span class="bold">\(.*\)$' 1 <<< "$PAGE")
            fi
        done
    fi

    [ -n "$COOKIE_FILE" ] && rm -f "$COOKIE_FILE"

    LINKS=$(replace_all 'href="' "$BASE_URL" <<< "$LINKS")
    NAMES=$(replace_all '</span>' '' <<< "$NAMES")

    list_submit "$LINKS" "$NAMES"

    # Are there any subfolders?
    if [ -n "$REC" ]; then
        local FOLDERS FOLDER

        FOLDERS=$(parse_all_quiet \
            '^[[:space:]]*<a href=".*" rel="[0-9]\+" title=".*">[[:space:]]*$' \
            '\(href="[^"]\+\)' <<< "$PAGE") || return
        FOLDERS=$(replace_all 'href="' "$BASE_URL" <<< "$FOLDERS")

        while read FOLDER; do
            [ -z "$FOLDER" ] && continue
            log_debug "Entering sub folder: $FOLDER"
            chomikuj_list "$FOLDER" "$REC"
        done <<< "$FOLDERS"
    fi

    return 0
}
