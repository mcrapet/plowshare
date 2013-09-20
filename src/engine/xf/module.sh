#!/bin/bash
#
# xfilesharing template module
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

MODULE_XFILESHARING_REGEXP_URL="https\?://"

MODULE_XFILESHARING_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_XFILESHARING_DOWNLOAD_RESUME=yes
MODULE_XFILESHARING_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_XFILESHARING_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_XFILESHARING_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
FOLDER,,folder,s=FOLDER,Folder to upload files into
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email
PREMIUM,,premium,,Make file inaccessible to non-premium users
PRIVATE_FILE,,private,,Do not make file visible in folder view"
MODULE_XFILESHARING_UPLOAD_REMOTE_SUPPORT=yes

MODULE_XFILESHARING_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=()

MODULE_XFILESHARING_DELETE_OPTIONS=""
MODULE_XFILESHARING_PROBE_OPTIONS=""
MODULE_XFILESHARING_LIST_OPTIONS=""

# CloudFlare antiDDoS protection handler
# $1: cooke file
# $2: referer URL (usually main URL)
# $3: (X)HTML page data
# stdout: (X)HTML page data
xfilesharing_check_cloudflare_antiddos() {
    local -r COOKIE_FILE=$1
    local -r REFERER=$2
    local PAGE=$3
    local -r BASE_URL=$(basename_url "$REFERER")

    if match 'DDoS protection by CloudFlare\|CloudFlare Ray ID' "$PAGE"; then
        local FORM_DDOS FORM_DDOS_VC FORM_DDOS_ACTION DDOS_CHLNG DOMAIN

        log_debug "CloudFlare DDoS protection detected."

        if match 'The web server reported a bad gateway error' "$PAGE"; then
            log_error 'CloudFlare bad gateway. Try again later.'
            return $ERR_LINK_TEMP_UNAVAILABLE
            #return $ERR_FATAL
        fi

        FORM_DDOS=$(grep_form_by_id "$PAGE" 'challenge-form') || return
        FORM_DDOS_ACTION=$(echo "$PAGE" | parse_form_action) || return
        FORM_DDOS_VC=$(echo "$FORM_DDOS" | parse_form_input_by_name 'jschl_vc') || return
        DDOS_CHLNG=$(echo "$PAGE" | parse 'a.value = ' 'a.value = \([^;]\+\)') || return
        DOMAIN=$(echo "$BASE_URL" | parse . '^https\?://\(.*\)$')
        DDOS_CHLNG=$(( ($DDOS_CHLNG) + ${#DOMAIN} ))

        wait 6 || return

        PAGE=$(curl -i -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' -G \
            -e "$REFERER" \
            -d "jschl_vc=$FORM_DDOS_VC" \
            -d "jschl_answer=$DDOS_CHLNG" \
            "$BASE_URL$FORM_DDOS_ACTION" | \
            strip_html_comments) || return
    fi

    echo "$PAGE"
    return 0          
}

# Unpack packed(obfuscated) js code
# $1: js script to unpack
# stdout: unpacked js script
xfilesharing_unpack_js() {
    local PACKED_SCRIPT=$1
    local UNPACK_SCRIPT

    UNPACK_SCRIPT="
    //////////////////////////////////////////
    //  Un pack the code from the /packer/  //
    //  By matthew@matthewfl.com            //
    //  http://matthewfl.com/unPacker.html  //
    //////////////////////////////////////////
    function unPack(code) {
        code = unescape(code);
        var env = {
            eval: function(c) {
                code = c;
            },
            window: {},
            document: {}
        };
        eval(\"with(env) {\" + code + \"}\");
        code = (code + \"\").replace(/;/g, \";\\n\").replace(/{/g, \"\\n{\\n\").replace(/}/g, \"\\n}\\n\").replace(/\\n;\\n/g, \";\\n\").replace(/\\n\\n/g, \"\\n\");
        return code;
    }"

    # urlencoding script with all quotes and backslashes to push it into unpack function as string
    PACKED_SCRIPT=$(echo "$PACKED_SCRIPT" | uri_encode_strict | replace '\' '%5C')
    echo "$PACKED_SCRIPT_CLEAN $UNPACK_SCRIPT print(unPack('$PACKED_SCRIPT'));" | javascript || return
}

# Output a file download URL
# $1: cookie file
# $2: file hosting url
# stdout: real file download link
xfilesharing_download() {
    local -r COOKIE_FILE=$1
    local URL=$2

    local BASE_URL=$(basename_url "$URL")
    local PAGE LOCATION EXTRA FILE_URL WAIT_TIME TIME ERROR
    local FORM_DATA FORM_CAPTCHA FORM_PASSWORD
    local NEW_PAGE=1

    if [ -n "$AUTH" ]; then
        xfilesharing_login "$COOKIE_FILE" "$BASE_URL" "$AUTH" || return
    fi

    PAGE=$(curl -i -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' "$URL" | \
            strip_html_comments) || return

    PAGE=$(xfilesharing_check_cloudflare_antiddos "$COOKIE_FILE" "$URL" "$PAGE") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)
    if [ -n "$LOCATION" ] && [ "$LOCATION" != "$URL" ]; then
        if [ $(basename_url "$LOCATION") = "$LOCATION" ]; then
            URL="$BASE_URL/$LOCATION"
        elif match 'op=login' "$LOCATION"; then
            log_error "You must be registered to download."
            return $ERR_LINK_NEED_PERMISSIONS
        else
            URL="$LOCATION"
        fi
        log_debug "New form action: '$URL'"
    fi

    xfilesharing_dl_parse_error "$PAGE" || return

    xfilesharing_dl_parse_imagehosting "$PAGE" && return 0

    # Streaming sites like to pack player scripts and place them where they like
    xfilesharing_dl_parse_streaming "$PAGE" "$URL" && return 0

    # First form sometimes absent
    FORM_DATA=$(xfilesharing_dl_parse_form1 "$PAGE") || return
    if [ -n "$FORM_DATA" ]; then
        { read -r FILE_NAME_TMP; } <<<"$FORM_DATA"
        [ -n "$FILE_NAME_TMP" ] && FILE_NAME=$(echo "$FILE_NAME_TMP" | parse . '=\(.*\)$')

        WAIT_TIME=$(xfilesharing_dl_parse_countdown "$PAGE") || return
        if [ -n "$WAIT_TIME" ]; then
            wait $WAIT_TIME || return
        fi

        PAGE=$(xfilesharing_dl_commit_step1 "$COOKIE_FILE" "$URL" "$FORM_DATA") || return

        # To avoid double check for errors or streaming if page not updated
        NEW_PAGE=1
    else
        log_debug 'Form 1 omitted.'
    fi

    if [ $NEW_PAGE = 1 ]; then
        xfilesharing_dl_parse_error "$PAGE" || return
        xfilesharing_dl_parse_streaming "$PAGE" "$URL" "$FILE_NAME" && return 0
        NEW_PAGE=0
    fi

    FORM_DATA=$(xfilesharing_dl_parse_form2 "$PAGE") || return
    if [ -n "$FORM_DATA" ]; then
        { read -r FILE_NAME_TMP; } <<<"$FORM_DATA"
        [ -n "$FILE_NAME_TMP" ] && FILE_NAME=$(echo "$FILE_NAME_TMP" | parse . '=\(.*\)$')

        WAIT_TIME=$(xfilesharing_dl_parse_countdown "$PAGE") || return

        # If password or captcha is too long :)
        [ -n "$WAIT_TIME" ] && TIME=$(date +%s)

        CAPTCHA_DATA=$(xfilesharing_handle_captcha "$PAGE") || return
        { read FORM_CAPTCHA; read CAPTCHA_ID; } <<<"$CAPTCHA_DATA"

        if [ -n "$WAIT_TIME" ]; then
            TIME=$(($(date +%s) - $TIME))
            if [ $TIME -lt $WAIT_TIME ]; then
                WAIT_TIME=$((WAIT_TIME - $TIME))
                wait $WAIT_TIME || return
            fi
        fi

        PAGE=$(xfilesharing_dl_commit_step2 "$COOKIE_FILE" "$URL" "$FORM_DATA" \
            "$FORM_CAPTCHA") || return

        # In case of download-after-post system or some complicated link parsing
        #  that requires additional data and page rquests (like uploadc or up.lds.net)
        if match_remote_url $(echo "$PAGE" | first_line); then
            { read FILE_URL; read FILE_NAME_TMP; read EXTRA; } <<<"$PAGE"
            [ -n "$FILE_NAME_TMP" ] && FILE_NAME="$FILE_NAME_TMP"
            [ -n "$EXTRA" ] && eval "$EXTRA"
        else
            NEW_PAGE=1
        fi
    else
        log_debug 'Form 2 omitted.'
    fi

    if [ -z "$FILE_URL" ]; then
        if [ $NEW_PAGE = 1 ]; then
            xfilesharing_dl_parse_error "$PAGE" || ERROR=$?
            if [ "$ERROR" = "$ERR_CAPTCHA" ]; then
                log_debug 'Wrong captcha'
                [ -n "$CAPTCHA_ID" ] && captcha_nack $CAPTCHA_ID
            fi
            [ -n "$ERROR" ] && return $ERROR
            xfilesharing_dl_parse_streaming "$PAGE" "$URL" "$FILE_NAME" && return 0
        fi

        # I think it would be correct to use parse fucntion to parse only,
        #  but not make any additional requests
        FILE_DATA=$(xfilesharing_dl_parse_final_link "$PAGE" "$FILE_NAME") || return
        { read FILE_URL; read FILE_NAME_TMP; read EXTRA; } <<<"$FILE_DATA"
        [ -n "$FILE_NAME_TMP" ] && FILE_NAME="$FILE_NAME_TMP"
        [ -n "$EXTRA" ] && eval "$EXTRA"
    fi

    if match_remote_url "$FILE_URL"; then
        if [ -n "$FORM_CAPTCHA" -a -n "$CAPTCHA_ID" ]; then
            log_debug 'Correct captcha'
            captcha_ack $CAPTCHA_ID
        fi

        echo "$FILE_URL"
        [ -n "$FILE_NAME" ] && echo "$FILE_NAME"
        return 0
    fi

    log_debug 'Link not found'

    # Can be wrong captcha, some sites (cramit.in) do not return any error message
    if [ -n "$FORM_CAPTCHA" ]; then
        log_debug 'Wrong captcha'
        [ -n "$CAPTCHA_ID" ] && captcha_nack $CAPTCHA_ID
        return $ERR_CAPTCHA
    else
        log_error 'Unexpected content.'
    fi

    return $ERR_FATAL
}

# Upload a file to file hosing
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
xfilesharing_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL=$(echo "$URL_UPLOAD" | parse . "^\(.*\)/")
    local PAGE LOCATION STATE FILE_CODE DEL_CODE FILE_ID FORM_DATA RESULT_DATA
    local FILE_NEED_EDIT=0

    log_debug "Current: $URL_UPLOAD"

    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif [ -n "$PREMIUM" ]; then
            log_error 'You must be registered to create premium-only downloads.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    if [ -n "$AUTH" ]; then
        xfilesharing_login "$COOKIE_FILE" "$BASE_URL" "$AUTH" || return

        if ! match_remote_url "$FILE"; then
            FILE_SIZE=$(get_filesize "$FILE")
            #if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
            #    log_debug "File is bigger than $MAX_SIZE"
            #    return $ERR_SIZE_LIMIT_EXCEEDED
            #fi

            xfilesharing_ul_check_freespace "$COOKIE_FILE" "$BASE_URL" "$FILE_SIZE" || return
        else
            FILE_NEED_EDIT=1
        fi            

        if [ -n "$FOLDER" ]; then
            FOLDER_DATA=$(xfilesharing_ul_get_folder_data "$COOKIE_FILE" "$BASE_URL" "$FOLDER") || return

            if [ -z "$FOLDER_DATA" ]; then
                xfilesharing_ul_create_folder "$COOKIE_FILE" "$BASE_URL" "$FOLDER" || return
                FOLDER_DATA=$(xfilesharing_ul_get_folder_data "$COOKIE_FILE" "$BASE_URL" "$FOLDER") || return
            elif [ "$FOLDER_DATA" = "0" ]; then
                log_debug 'Folders not supported or broken for current submodule.'
            fi
        fi          
    fi

    PAGE=$(curl -i -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" -b 'lang=english' \
        "$URL_UPLOAD" | \
        strip_html_comments) || return

    PAGE=$(xfilesharing_check_cloudflare_antiddos "$COOKIE_FILE" "$URL_UPLOAD" "$PAGE") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)
    if match 'op=login' "$LOCATION"; then
        log_error 'Anonymous upload not allowed.'
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FORM_DATA=$(xfilesharing_ul_parse_data "$PAGE") || return

    PAGE=$(xfilesharing_ul_commit "$COOKIE_FILE" "$BASE_URL" "$FILE" "$DEST_FILE" "$FORM_DATA") || return

    RESULT_DATA=$(xfilesharing_ul_parse_result "$PAGE") || return
    { read STATE; read FILE_CODE; read DEL_CODE; read FILE_NAME; } <<<"$RESULT_DATA"

    if [ -z "$FILE_NAME" ] && [ "$DEST_FILE" != 'dummy' ]; then
        FILE_NAME="$DEST_FILE"
    fi    

    if [ "$STATE" = 'EDIT' ]; then
        STATE='OK'
        FILE_NEED_EDIT=1
    fi

    xfilesharing_ul_handle_state "$STATE" || return

    PAGE=$(xfilesharing_ul_commit_result "$COOKIE_FILE" "$BASE_URL" "$RESULT_DATA") || return

    if [ -z "$DEL_CODE" -a -n "$PAGE" ]; then
        DEL_CODE=$(xfilesharing_ul_parse_del_code "$PAGE")
    fi

    if [ -n "$AUTH" ]; then
        FILE_ID=$(xfilesharing_ul_parse_file_id "$PAGE")

        [ -z "$FILE_ID" ] && FILE_ID=$(xfilesharing_ul_get_file_id "$COOKIE_FILE" "$BASE_URL")

        [ -n "$FILE_ID" ] && log_debug "File ID: '$FILE_ID'"
    fi

    # Move file to a folder?
    if [ -n "$FOLDER" -a -z "$FILE_ID" ]; then
        log_error 'Cannot move file without file ID.'
    elif [ -n "$FOLDER" ] && [ "$FOLDER_DATA" = "0" ]; then
        log_error 'Skipping move file.'
    elif [ -n "$FOLDER" ]; then
        xfilesharing_ul_move_file "$COOKIE_FILE" "$BASE_URL" "$FILE_ID" "$FOLDER_DATA" || return
    fi

    # Edit file if could not set some options during upload
    if [ "$FILE_NEED_EDIT" = 1 ] && \
        [ "$DEST_FILE" != 'dummy' \
        -o -n "$DESCRIPTION" \
        -o -n "$LINK_PASSWORD" ] ; then
        log_debug 'Editing file parameters for remote upload...'

        xfilesharing_ul_edit_file "$COOKIE_FILE" "$BASE_URL" "$FILE_CODE" "$DEST_FILE" || return

    else
        # Set premium only flag
        if [ -n "$PREMIUM" -a -z "$FILE_ID" ]; then
            log_error 'Cannot set premium flag without file ID.'
        elif [ -n "$PREMIUM" ]; then
            xfilesharing_ul_set_flag_premium "$COOKIE_FILE" "$BASE_URL" "$FILE_ID" || return
        fi

        # Ensure that correct public flag set on remote upload
        if [ "$FILE_NEED_EDIT" = 1 ] && [ -z "$FILE_ID" ]; then
            log_error 'Cannot set public flag without file ID.'
        elif [ "$FILE_NEED_EDIT" = 1 ]; then
            xfilesharing_ul_set_flag_public "$COOKIE_FILE" "$BASE_URL" "$FILE_ID" || return
        fi
    fi

    xfilesharing_ul_generate_links "$BASE_URL" "$FILE_CODE" "$DEL_CODE" "$FILE_NAME"
}

# Delete a file uploaded to file hosting
# $1: cookie file (unused here)
# $2: delete url
xfilesharing_delete() {
    local -r URL=$2
    local -r BASE_URL=$XF_BASE_URL
    local PAGE FILE_ID FILE_DEL_ID

    if ! match 'killcode=[[:alnum:]]\+' "$URL"; then
        log_error 'Invalid URL format'
        return $ERR_BAD_COMMAND_LINE
    fi

    FILE_ID=$(parse . "^$BASE_URL/\([[:alnum:]]\+\)" <<< "$URL")
    FILE_DEL_ID=$(parse . 'killcode=\([[:alnum:]]\+\)$' <<< "$URL")

    PAGE=$(curl -b 'lang=english' -e "$URL" \
        -d 'op=del_file' \
        -d "id=$FILE_ID" \
        -d "del_id=$FILE_DEL_ID" \
        -d 'confirm=yes' \
        "$BASE_URL/") || return

    if match 'File deleted successfully' "$PAGE"; then
        return 0
    elif match 'No such file exist' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match 'Wrong Delete ID' "$PAGE"; then
        log_error 'Wrong delete ID'
    fi

    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: file hosting url
# $3: requested capability list
# stdout: 1 capability per line
xfilesharing_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -b 'lang=english' "$URL") || return

    if match 'File Not Found\|file was removed' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_REFERER FORM_METHOD_F
    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname') || return
    FORM_REFERER=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'referer')
    FORM_METHOD_F=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')

    PAGE=$(curl -b 'lang=english' \
        -d "op=$FORM_OP" \
        -d "usr_login=$FORM_USR" \
        -d "id=$FORM_ID" \
        --data-urlencode "fname=$FORM_FNAME" \
        -d "referer=$FORM_REFERER" \
        -d "method_free=$FORM_METHOD_F" \
        "$URL") || return

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$FORM_FNAME" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'Size:' \
            '<td>\(.*\)$' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a file hositng web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
xfilesharing_list() {
    local -r URL=$1
    local -r REC=$2
    local RET=$ERR_LINK_DEAD
    local PAGE LINKS NAMES ERROR PAGE_NUMBER LAST_PAGE

    PAGE=$(curl -b 'lang=english' "$URL") || return

    ERROR=$(echo "$PAGE" | parse_tag_quiet 'class="err"' 'font')
    if [ "$ERROR" = 'No such user exist' ]; then
        return $ERR_LINK_DEAD
    elif [ -n "$ERROR" ]; then
        log_error "Remote error: $ERROR"
        return $ERR_FATAL
    fi

    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'class="link"' 'href')
    NAMES=$(echo "$PAGE" | parse_all_tag_quiet 'class="link"' 'a')

    # Parse page buttons panel if exist
    LAST_PAGE=$(echo "$PAGE" | parse_tag_quiet 'class="paging"' 'div' | break_html_lines | \
        parse_all_quiet . 'page=\([0-9]\+\)')

    if [ -n "$LAST_PAGE" ];then
        # The last button is 'Next', last page button right before
        LAST_PAGE=$(echo "$LAST_PAGE" | delete_last_line | last_line)

        for (( PAGE_NUMBER=2; PAGE_NUMBER<=LAST_PAGE; PAGE_NUMBER++ )); do
            log_debug "Listing page #$PAGE_NUMBER"

            PAGE=$(curl -G \
                -d "page=$PAGE_NUMBER" \
                "$URL") || return

            LINKS=$LINKS$'\n'$(echo "$PAGE" | parse_all_attr_quiet 'class="link"' 'href')
            NAMES=$NAMES$'\n'$(echo "$PAGE" | parse_all_tag_quiet 'class="link"' 'a')
        done
    fi

    list_submit "$LINKS" "$NAMES" && RET=0

    # Are there any subfolders?
    if [ -n "$REC" ]; then
        local FOLDERS FOLDER

        FOLDERS=$(echo "$PAGE" | parse_all_attr_quiet 'folder2.gif' 'href') || return

        # First folder can be parent folder (". .") - drop it to avoid infinite loops
        FOLDER=$(echo "$PAGE" | parse_tag_quiet 'folder2.gif' 'b') || return
        [ "$FOLDER" = '. .' ] && FOLDERS=$(echo "$FOLDERS" | delete_first_line)

        while read FOLDER; do
            [ -z "$FOLDER" ] && continue
            log_debug "Entering sub folder: $FOLDER"
            xfilesharing_list "$FOLDER" "$REC" && RET=0
        done <<< "$FOLDERS"
    fi

    return $RET
}
