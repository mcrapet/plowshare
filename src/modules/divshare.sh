# Plowshare divshare.com module
# Copyright (c) 2010-2014 Plowshare team
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

MODULE_DIVSHARE_REGEXP_URL='https\?://\(www\.\)\?divshare\.com/'

MODULE_DIVSHARE_DOWNLOAD_OPTIONS=""
MODULE_DIVSHARE_DOWNLOAD_RESUME=no
MODULE_DIVSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_DIVSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_DIVSHARE_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
FOLDER,,folder,s=FOLDER,Folder to upload files into
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_DIVSHARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_DIVSHARE_DELETE_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"

MODULE_DIVSHARE_LIST_OPTIONS="
DIRECT,,direct,,Output direct (HTTP) links for images in a gallery"
MODULE_DIVSHARE_LIST_HAS_SUBFOLDERS=yes

MODULE_DIVSHARE_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
divshare_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE STATUS NAME

    LOGIN_DATA='user_email=$USER&user_password=$PASSWORD&login_submit=Log+in+%3E'
    PAGE=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
       "$BASE_URL/login" -b "$COOKIE_FILE" -L) || return

    STATUS=$(parse_cookie_quiet 'ds_login_2' < "$COOKIE_FILE")
    [ -n "$STATUS" ] || return $ERR_LOGIN_FAILED

    NAME=$(echo "$PAGE" | parse 'logged in as' \
        '^[[:space:]]*logged in as \(.\+\) |') || return

    log_debug "Successfully logged in as member '$NAME'"
}

# Check if specified folder name is valid.
# When multiple folders wear the same name, first one is taken.
# $1: source code of main page
# $2: folder name selected by user
# stdout: folder ID
divshare_check_folder() {
    local -r PAGE=$1
    local -r NAME=$2
    local LINES FOLDERS FOL

    # - Extract the line containing all <option> tags for folders
    # - Split them so we have one tag per line for later parsing
    LINES=$(echo "$PAGE" | parse '<select name="gallery_id"' \
        '^[[:space:]]*\(.*\)[[:space:]]*$' 2 | break_html_lines) || return

    # <option value="ID">NAME</option>
    FOLDERS=$(echo "$LINES" | parse_all_tag option) || return
    if [ -z "$FOLDERS" ]; then
        log_error 'No folder found, site updated?'
        return $ERR_FATAL
    fi

    log_debug 'Available folders:' $FOLDERS

    while IFS= read -r FOL; do
        if [ "$FOL" = "$NAME" ]; then
            echo "$LINES" | parse_attr "<option.*>$FOL</option>" 'value' || return
            return 0
        fi
    done <<< "$FOLDERS"

    log_error "Invalid folder, choose from:" $FOLDERS
    return $ERR_BAD_COMMAND_LINE
}

# Extract file id from download link
# $1: divshare url
# stdout: file id
divshare_extract_file_id() {
    local FILE_ID

    FILE_ID=$(echo "$1" | parse '.' \
        'download/\([[:digit:]]\{8\}\)-[[:alnum:]]\{3\}$') || return
    log_debug "File ID: '$FILE_ID'"

    echo "$FILE_ID"
}

# Output a divshare file download URL
# $1: cookie file
# $2: divshare url
# stdout: real file download link
divshare_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.divshare.com'
    local PAGE REDIR_URL WAIT_PAGE WAIT_TIME FILE_URL FILENAME

    PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return

    if match '>Sorry, we couldn.t find this file\.<\|>DivShare - File Not Found<' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # Uploader can disable audio/video download (only streaming is available)
    REDIR_URL=$(echo "$PAGE" | parse_attr_quiet 'btn_download_new' 'href') || {
        log_error 'content download not allowed';
        return $ERR_LINK_DEAD;
    }

    if ! match_remote_url "$REDIR_URL"; then
        WAIT_PAGE=$(curl -b "$COOKIE_FILE" "${BASE_URL}$REDIR_URL") || return
        WAIT_TIME=$(echo "$WAIT_PAGE" | parse_quiet 'http-equiv="refresh"' 'content="\([^;]*\)')
        REDIR_URL=$(echo "$WAIT_PAGE" | parse 'http-equiv="refresh"' 'url=\([^"]*\)') || return

        # Usual wait time is 15 seconds
        wait $((WAIT_TIME)) || return

        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL$REDIR_URL") || return
    fi

    FILE_URL=$(echo "$PAGE" | parse_attr 'btn_download_new' 'href') || return
    FILENAME=$(echo "$PAGE" | parse_tag title)

    echo $FILE_URL
    echo "${FILENAME% - DivShare}"
}

# Upload a file to DivShare
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: divshare download link
divshare_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.divshare.com'
    local FOLDER_ID=0

    local PAGE UP_URL FOLDER_OPT SIZE MAX_SIZE LINK

    test "$AUTH_FREE" || return $ERR_LINK_NEED_PERMISSIONS
    divshare_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

    # Capture (+ follow) redirect to the actual upload server
    PAGE=$(curl -b "$COOKIE_FILE" -L -i "$BASE_URL/upload") || return
    UP_URL=$(echo "$PAGE" | grep_http_header_location) || return
    MAX_SIZE=$(echo "$PAGE" | \
        parse_form_input_by_name_quiet 'MAX_FILE_SIZE') || return

    test "$MAX_SIZE" || MAX_SIZE=$(( 200 * 1024 * 1024 ))

    # Check file size
    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # If user chose a folder, check it now
    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(divshare_check_folder "$PAGE" "$FOLDER") || return
        FOLDER_OPT='-F gallery=on'
    fi

    log_debug "Upload URL: '$UP_URL'"
    log_debug "Folder ID: '$FOLDER_ID'"

    # Upload file
    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        -F 'upload_method=php' -F "MAX_FILE_SIZE=$MAX_SIZE" \
        -F "file1=@$FILE;filename=$DEST_FILE" \
        -F 'description[0]=' \
        -F 'file2=;type=application/octet-stream;filename=' \
        -F 'file2_description=Description' \
        -F 'file3=;type=application/octet-stream;filename=' \
        -F 'file3_description=Description' \
        -F 'file4=;type=application/octet-stream;filename=' \
        -F 'file4_description=Description' \
        -F 'file5=;type=application/octet-stream;filename=' \
        -F 'file5_description=Description' \
        $FOLDER_OPT \
        -F "gallery_id=$FOLDER_ID" -F 'gallery_title=' -F 'gallery_password=' \
        -F "email_to=$TOEMAIL" -F 'terms=on' "$UP_URL") || return

    # <img src="http://divshare.com/images/v4/upload/files_uploaded_text.png">
    # Share them with this links.
    if match 'Share them with this links.' "$PAGE"; then

        # Extract link
        LINK=$(echo "$PAGE" | parse_tag "$BASE_URL/download/" 'a') || return

    # <title>DivShare - Upload Error</title>
    elif match '<title>.*Upload Error</title>' "$PAGE"; then

        # Sorry, we can't upload a file of this type. Some files, particularly executable ones, pose a security risk to our server and our users.
        if match "Sorry, we can't upload a file of this type\." "$PAGE"; then
            log_error 'Banned file type. Try changing the extension.'

        # Sorry, we couldn't process the image "pic.jpg" &mdash; it may not be a valid JPG, GIF or PNG file.
        elif match "Sorry, we couldn't process the image" "$PAGE"; then
            log_error 'Server refuses to accept corrupt image file.'

        else
            local ERROR=$(echo "$PAGE" | \
                parse_quiet '<div class="errors_v4">' '^\(.*\)$')
            log_error "Site reports upload error: $ERROR"
        fi

        return $ERR_FATAL

    else
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    # Do we need to edit the file? (set description)
    if [ -n "$DESCRIPTION" ]; then
        local FILE_ID

        FILE_ID=$(divshare_extract_file_id "$LINK") || return
        PAGE=$(curl -b "$COOKIE_FILE" -F "desc_id=$FILE_ID" \
            --form-string "description=$DESCRIPTION" -F 'v3=true' \
            "$BASE_URL/scripts/ajax/description.php") || return

        match "$DESCRIPTION" "$PAGE" || \
            log_error 'Could not edit description. Site update?'
    fi

    # Output link and delete link (which is actually the same)
    echo "$LINK"
    echo "$LINK"
}

# Delete a file from DivShare
# $1: cookie file
# $2: divshare (download) link
divshare_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.divshare.com'
    local -r FILE_GONE_MSG="Sorry, we couldn't find this file"
    local PAGE FILE_ID

    test "$AUTH_FREE" || return $ERR_LINK_NEED_PERMISSIONS
    divshare_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

    # Check if file exists
    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return
    match "$FILE_GONE_MSG" "$PAGE" && return $ERR_LINK_DEAD

    FILE_ID=$(divshare_extract_file_id "$URL") || return

    PAGE=$(curl -b "$COOKIE_FILE" -d "files%5B%5D=$FILE_ID" -d 'folders%5B%5D=' \
        "$BASE_URL/scripts/v3/ajax/dash/delete.php") || return

    # We expect an empty reply
    if [ -n "$PAGE" ]; then
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    # Check if the file is gone
    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return
    if ! match "$FILE_GONE_MSG" "$PAGE"; then
        log_error 'Could not delete file.'
        return $ERR_FATAL
    fi
}

# List a DivShare web folder URL
# $1: divshare URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
divshare_list() {
    local -r URL=$1
    local -r REC=$2
    local -r BASE_URL='http://www.divshare.com'
    local RET=$ERR_LINK_DEAD
    local PREFIX="$BASE_URL"
    local PAGE LINK_DIVS LINKS NAMES

    if ! match "$BASE_URL/\(folder\|gallery\)/" "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    # Note: Galleries redirect to slideshow of first contained image
    PAGE=$(curl -i "$URL") || return

    # Extract all the DIV tags which hold the file links (all in one line)
    # Note: parse_all_tag doesn't work here because </div> is on a new line
    LINK_DIVS=$(echo "$PAGE" | break_html_lines | \
        parse_all_quiet 'class="folder_file_list"' '^\(.*\)$')

    if match 'folder' "$URL"; then
        # Normal folder - extract individual links and file names
        LINKS=$(echo "$LINK_DIVS" | parse_all_attr '/icons/files' 'href') || return
        NAMES=$(echo "$LINK_DIVS" | parse_all_attr '/icons/files' 'title' | \
            uri_decode) || return

    else
        # Gallery - get all pictures (has no file names)
        local SHOW_URL SHOW_ID

        SHOW_URL=$(echo "$PAGE" | grep_http_header_location) || return
        SHOW_ID=${SHOW_URL##*/}
        PAGE=$(curl "$BASE_URL/embed/slideshow/$SHOW_ID") || return

        # extract just the IDs of all images so we can make up correct links
        LINKS=$(echo "$PAGE" | parse_all 'img' \
            'src=.*/\([[:digit:]]\{8\}-[[:alnum:]]\{3\}\)" ') || return

        if [ -n "$DIRECT" ]; then
            PREFIX="$BASE_URL/img/"
        else
            PREFIX="$BASE_URL/download/"
        fi
    fi

    list_submit "$LINKS" "$NAMES" "$PREFIX" && RET=0

    # Are there any subfolders?
    if [ -n "$REC" ] && match '/icons/\(folder\|gallery\)' "$LINK_DIVS"; then
        local FOLDERS FOLDER

        FOLDERS=$(echo "$LINK_DIVS" | \
            parse_all_attr '/icons/\(folder\|gallery\)' 'href') || return

        while read FOLDER; do
            log_debug "entering sub folder: $BASE_URL$FOLDER"
            divshare_list "$BASE_URL$FOLDER" "$REC" && RET=0
        done <<< "$FOLDERS"
    fi

    return $RET
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: divshare url
# $3: requested capability list
# stdout: 1 capability per line
divshare_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_NAME REQ_OUT

    PAGE=$(curl "$URL") || return

    if match '>Sorry, we couldn.t find this file\.<\|>DivShare - File Not Found<' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        #  <meta property="og:audio:title" content="..."
        FILE_NAME=$(parse_attr_quiet '=.og:audio:title.' content <<< "$PAGE")

        test -z "$FILE_NAME" &&
            FILE_NAME=$(parse_tag_quiet title <<< "$PAGE") && FILE_NAME=${FILE_NAME% - DivShare}

        test -n "$FILE_NAME" && echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    echo $REQ_OUT
}
