#!/bin/bash
#
# xfilesharing generic functions
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

# Simple quotes are mandatory. Bash4 bug?
# http://unix.stackexchange.com/questions/56815/how-to-initialize-a-read-only-global-associative-array-in-bash
declare -rgA 'GENERIC_FUNCS=(
    [login]=xfilesharing_login_generic
    [handle_captcha]=xfilesharing_handle_captcha_generic
    [dl_parse_error]=xfilesharing_dl_parse_error_generic
    [dl_parse_form1]=xfilesharing_dl_parse_form1_generic
    [dl_parse_form2]=xfilesharing_dl_parse_form2_generic
    [dl_parse_final_link]=xfilesharing_dl_parse_final_link_generic
    [dl_commit_step1]=xfilesharing_dl_commit_step1_generic
    [dl_commit_step2]=xfilesharing_dl_commit_step2_generic
    [dl_parse_streaming]=xfilesharing_dl_parse_streaming_generic
    [dl_parse_imagehosting]=xfilesharing_dl_parse_imagehosting_generic
    [dl_parse_countdown]=xfilesharing_dl_parse_countdown_generic
    [ul_get_space_data]=xfilesharing_ul_get_space_data_generic
    [ul_get_folder_data]=xfilesharing_ul_get_folder_data_generic
    [ul_create_folder]=xfilesharing_ul_create_folder_generic
    [ul_get_file_id]=xfilesharing_ul_get_file_id_generic
    [ul_parse_data]=xfilesharing_ul_parse_data_generic
    [ul_commit]=xfilesharing_ul_commit_generic
    [ul_parse_result]=xfilesharing_ul_parse_result_generic
    [ul_commit_result]=xfilesharing_ul_commit_result_generic
    [ul_handle_state]=xfilesharing_ul_handle_state_generic
    [ul_parse_del_code]=xfilesharing_ul_parse_del_code_generic
    [ul_parse_file_id]=xfilesharing_ul_parse_file_id_generic
    [ul_move_file]=xfilesharing_ul_move_file_generic
    [ul_edit_file]=xfilesharing_ul_edit_file_generic
    [ul_set_flag_premium]=xfilesharing_ul_set_flag_premium_generic
    [ul_set_flag_public]=xfilesharing_ul_set_flag_public_generic
    [ul_generate_links]=xfilesharing_ul_generate_links_generic
    [ul_remote_queue_test]=xfilesharing_ul_remote_queue_test_generic
    [ul_remote_queue_check]=xfilesharing_ul_remote_queue_check_generic
    [ul_remote_queue_add]=xfilesharing_ul_remote_queue_add_generic
    [ul_remote_queue_del]=xfilesharing_ul_remote_queue_del_generic
    [ul_get_file_code]=xfilesharing_ul_get_file_code_generic
    [pr_parse_file_name]=xfilesharing_pr_parse_file_name_generic
    [pr_parse_file_size]=xfilesharing_pr_parse_file_size_generic
    [ls_parse_links]=xfilesharing_ls_parse_links_generic
    [ls_parse_names]=xfilesharing_ls_parse_names_generic
    [ls_parse_last_page]=xfilesharing_ls_parse_last_page_generic
    [ls_parse_folders]=xfilesharing_ls_parse_folders_generic)'

declare -rgA 'GENERIC_OPTIONS=(
    [DOWNLOAD_OPTIONS]="
        AUTH,a,auth,a=USER:PASSWORD,User account
        LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
    [DOWNLOAD_RESUME]=yes
    [DOWNLOAD_FINAL_LINK_NEEDS_COOKIE]=yes
    [DOWNLOAD_FINAL_LINK_NEEDS_EXTRA]=
    [DOWNLOAD_SUCCESSIVE_INTERVAL]=
    [UPLOAD_OPTIONS]="
        AUTH,a,auth,a=USER:PASSWORD,User account
        LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
        FOLDER,,folder,s=FOLDER,Folder to upload files into
        DESCRIPTION,d,description,S=DESCRIPTION,Set file description
        TOEMAIL,,email-to,e=EMAIL,<To> field for notification email
        PREMIUM,,premium,,Make file inaccessible to non-premium users
        PRIVATE_FILE,,private,,Do not make file visible in folder view
        ASYNC,,async,,Asynchronous remote upload"
    [UPLOAD_REMOTE_SUPPORT]=yes
    [DELETE_OPTIONS]=""
    [PROBE_OPTIONS]=""
    [LIST_OPTIONS]=""
    [LIST_HAS_SUBFOLDERS]=yes)'

# Static function. Proceed with login.
# $1: cookie file
# $2: base URL
# $3: authentication
# $4: login URL (optional)
# $?: 0 for success
xfilesharing_login_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r AUTH=$3
    local LOGIN_URL=$4
    local LOGIN_DATA LOGIN_RESULT STATUS NAME

    [ -z "$LOGIN_URL" ] && LOGIN_URL="$BASE_URL/"

    LOGIN_DATA='op=login&login=$USER&password=$PASSWORD&redirect='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA$BASE_URL/?op=my_account" \
        "$LOGIN_URL" -b 'lang=english') || return

    # If successful, entries are added into cookie file: login (optional) and xfss (or xfsts)
    STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
    if [ -z "$STATUS" ]; then
        STATUS=$(parse_cookie_quiet 'xfsts' < "$COOKIE_FILE")
        [ -n "$STATUS" ] && log_debug 'xfsts login cookie'
    fi

    if [ -z "$STATUS" ]; then
        return $ERR_LOGIN_FAILED
    fi

    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -z "$NAME" ]; then
        log_debug 'No login information in cookie.'
    else
        log_debug "Successfully logged in as $NAME."
    fi

    return 0
}

# Parse and handle captcha
# $1: (X)HTML page data
# stdout: captcha data prepaired for cURL (single line)
#         format "-d name=value -d name1=value1 ..."
#         or nothing if there is no captcha
xfilesharing_handle_captcha_generic() {
    local PAGE=$1
    local FORM_CODE ID

    if match 'captchas\|code\|recaptcha\|solvemedia' "$PAGE"; then
         if match 'recaptcha.*?k=' "$PAGE"; then
            local PUBKEY WCI CHALLENGE WORD ID

            log_debug 'CAPTCHA: reCaptcha'

            # http://www.google.com/recaptcha/api/challenge?k=
            # http://api.recaptcha.net/challenge?k=
            PUBKEY=$(echo "$PAGE" | parse 'recaptcha.*?k=' '?k=\([[:alnum:]_-.]\+\)') || return
            WCI=$(recaptcha_process $PUBKEY) || return
            { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

            FORM_CODE="-d recaptcha_challenge_field=$CHALLENGE -d recaptcha_response_field=$WORD"

        elif match 'solvemedia\.com.*?k=' "$PAGE"; then
            local PUBKEY RESP CHALLENGE ID

            log_debug 'CAPTCHA: Solve Media'

            # solvemedia.com/papi/challenge.script?k=
            PUBKEY=$(echo "$PAGE" | parse 'solvemedia\.com.*?k=' '?k=\([[:alnum:]_-.]\+\)') || return
            log_debug "Solvemedia pubkey: '$PUBKEY'"
            RESP=$(solvemedia_captcha_process $PUBKEY) || return
            { read CHALLENGE; read ID; } <<< "$RESP"

            FORM_CODE="-d adcopy_response=manual_challenge --data-urlencode adcopy_challenge=$CHALLENGE"

        # Two default xfilesharing captchas - image and text
        # Text captcha solver - Copy/Paste from uptobox
        elif match '/captchas/'  "$PAGE"; then
            local WI WORD ID CAPTCHA_URL CAPTCHA_IMG

            log_debug 'CAPTCHA: xfilesharing image'

            CAPTCHA_URL=$(echo "$PAGE" | parse_attr '/captchas/' src) || return
            CAPTCHA_IMG=$(create_tempfile '.jpg') || return

            curl -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || return

            WI=$(captcha_process "$CAPTCHA_IMG") || return
            { read WORD; read ID; } <<<"$WI"
            rm -f "$CAPTCHA_IMG"

            FORM_CODE="-d code=$WORD"

        elif match 'Enter code below:\|"captcha_code"' "$PAGE"; then
            local CODE OFFSET DIGIT DIGIT_N XCOORD LINE

            log_debug 'CAPTCHA: xfilesharing text'

            # Need to filter for bad non-tf8 characters, parse with offset glitches on such pages
            #  see enjoybox.in
            PAGE=$(echo "$PAGE" | iconv -c -t UTF-8 | break_html_lines_alt)

            CODE=0
            OFFSET=48
            for (( DIGIT_N=1; DIGIT_N<=7; DIGIT_N+=2 )); do
                # direction:ltr
                DIGIT=$(echo "$PAGE" | parse_quiet 'width:80px;height:26px;font:bold 13px Arial;background:#ccc;text-align:left;' '^&#\([[:digit:]]\+\);<' DIGIT_N+1) || return
                if [ -z $DIGIT ]; then
                    DIGIT=$(echo "$PAGE" | parse 'width:80px;height:26px;font:bold 13px Arial;background:#ccc;text-align:left;' '^\([[:digit:]]\+\)<' DIGIT_N+1) || return
                    OFFSET=0
                fi
                XCOORD=$(echo "$PAGE" | parse 'width:80px;height:26px;font:bold 13px Arial;background:#ccc;text-align:left;' '-left:\([[:digit:]]\+\)p' DIGIT_N) || return

                # Depending x, guess digit rank
                if (( XCOORD < 15 )); then
                    (( CODE = CODE + 1000 * (DIGIT-OFFSET) ))
                elif (( XCOORD < 30 )); then
                    (( CODE = CODE + 100 * (DIGIT-OFFSET) ))
                elif (( XCOORD < 50 )); then
                    (( CODE = CODE + 10 * (DIGIT-OFFSET) ))
                else
                    (( CODE = CODE + (DIGIT-OFFSET) ))
                fi
            done

            DIGIT_N="${#CODE}"
            if [ "$DIGIT_N" -lt 4 ]; then
                for (( ; DIGIT_N<4; DIGIT_N++ )); do
                    CODE="0$CODE"
                done
            fi

            FORM_CODE="-d code=$CODE"
        fi

        [ -n "$FORM_CODE" ] && log_debug "CAPTCHA data: $FORM_CODE"
    fi

    if [ -n "$FORM_CODE" ]; then
        echo "$FORM_CODE"
        echo "$ID"
    fi

    return 0
}

# Parse all download stage errors
# $1: (X)HTML page data
# $?: error code or 0 if no error
xfilesharing_dl_parse_error_generic() {
    local PAGE=$1
    local ERROR ERROR_NOBLOCK=0

    # Some sites give fake 'No such file No such user exist File not found' message in the
    #  hidden block for some reason
    #  www.killerleaks.com, www.lovevideo.tv (second page), imagewe.com, uploadhunt.com
    #  www.tusfiles.net, linkmixes.com and more
    # Cometfiles: No such file | No such user exist | File not found
    # Maybe will need to move this after form parsing and check only if there is no forms,
    #  but for now this should work
    if ! matchi 'No such file.*No such user exist.*File not found' "$PAGE" && \
        matchi 'File Not Found\|file was removed\|No such file' "$PAGE"; then
            return $ERR_LINK_DEAD
    fi

    if match 'class="err">' "$PAGE"; then
        log_debug 'Remote error detected.'

        ERROR=$(echo "$PAGE" | parse_quiet 'class="err">' 'class="err">\([^<]\+\)')
        [ -z "$ERROR" -o "${#ERROR}" -lt 3 ] && ERROR=$(echo "$PAGE" | replace $'\r' '' | replace $'\n' '' | \
            parse_quiet 'class="err">' 'class="err">\([^<]\+\)')

        if [ -z "$ERROR" -o "${#ERROR}" -lt 3 ]; then
            ERROR="$PAGE"
            ERROR_NOBLOCK=1
        fi
    elif match 'You have to wait\|You can download files up to\|Video [Ii][sn] [Ee]ncoding\|Wrong password\|Wrong captcha\|Skipped countdown\|This file is available for Premium Users only' "$PAGE"; then
        ERROR="$PAGE"
        ERROR_NOBLOCK=1
    fi

    [ -z "$ERROR" ] && return 0

    # You have reached the download-limit for free-users.<br>Get your own Premium-account now!<br>(Or wait 3 seconds)
    if match 'You have reached the download-limit.*wait[^)]*second' "$PAGE"; then
        local SECS

        SECS=$(echo "$PAGE" | \
            parse_quiet 'You have reached the download-limit' ' \([[:digit:]]\+\) second')
        echo "$SECS"

        return $ERR_LINK_TEMP_UNAVAILABLE

    # You have to wait X hours, X minutes, Y seconds till next download
    elif match 'You have to wait' "$PAGE"; then
        local HOURS MINS SECS

        HOURS=$(echo "$PAGE" | \
            parse_quiet 'You have to wait' ' \([[:digit:]]\+\) hour')
        MINS=$(echo "$PAGE" | \
            parse_quiet 'You have to wait' ' \([[:digit:]]\+\) minute')
        SECS=$(echo "$PAGE" | \
            parse_quiet 'You have to wait' ' \([[:digit:]]\+\) second')

        log_error 'Forced delay between downloads.'
        echo $(( HOURS * 60 * 60 + MINS * 60 + SECS ))
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match 'You can download files up to .* only' "$PAGE"; then
        return $ERR_SIZE_LIMIT_EXCEEDED

    elif match 'Video [Ii][sn] [Ee]ncoding' "$ERROR"; then
        log_error 'Video is encoding now. Try again later.'
        return $ERR_LINK_TEMP_UNAVAILABLE

    # <Center><b>This file is available for Premium Users only.</b>
    elif match 'This file is available for Premium Users only' "$ERROR"; then
        return $ERR_LINK_NEED_PERMISSIONS

    # Check this only if proper error block parsed
    elif [ $ERROR_NOBLOCK -eq 0 ] && matchi 'premium' "$ERROR"; then
        return $ERR_LINK_NEED_PERMISSIONS

    # Stage 2 errors
    elif match 'Wrong password' "$ERROR"; then
        return $ERR_LINK_PASSWORD_REQUIRED

    elif match 'Wrong captcha' "$ERROR"; then
        return $ERR_CAPTCHA

    elif match 'Skipped countdown' "$ERROR"; then
        # Can do a retry
        log_debug "Remote error: $ERROR"
        return $ERR_NETWORK
    fi

    if [ $ERROR_NOBLOCK = 1 ]; then
        log_error "Unknown remote error."
        return $ERR_FATAL
    fi

    log_error "Remote error: $ERROR"
    return $ERR_FATAL
}

# Parse first step form (download)
#   Usually nothing important here, used to display some commertial info before download.
#   Ommited frequently. Disabled for premium users.
# $1: (X)HTML page data
# $2-8   (optional) custom form field names
# $9-... (optional) additional form fields (for custom callbacks)
# stdout: form data prepaired for cURL
#         "name=value" for mandatory and "-d name=value" for optional or sparse fields
xfilesharing_dl_parse_form1_generic() {
    local -r PAGE=$1
    local -r FORM_STD_OP=${2:-'op'}
    local -r FORM_STD_ID=${3:-'id'}
    local -r FORM_STD_USR=${4:-'usr_login'}
    local -r FORM_STD_FNAME=${5:-'fname'}
    local -r FORM_STD_REFERER=${6:-'referer'}
    local -r FORM_STD_HASH=${7:-'hash'}
    local FORM_STD_METHOD_F=${8:-'method_free'}
    local FORM_HTML FORM_OP FORM_ID FORM_USR FORM_FNAME FORM_REFERER FORM_HASH FORM_METHOD_F FORM_ADD
    local FORM_COUNT=1

    if ! match "value=[\"']\?download2[\"']\?" "$PAGE" && ! match "value=[\"']\?download1[\"']\?" "$PAGE"; then
        log_error 'No forms found. Unexpected content.'
        return $ERR_FATAL
    elif match "value=[\"']\?download2[\"']\?" "$PAGE" && ! match "value=[\"']\?download1[\"']\?" "$PAGE"; then
        return 0
    fi

    # First form is nameless and can be placed anywhere, only clue is 'op' = 'download1'
    while [ "$FORM_OP" != 'download1' ]; do
        log_debug "Searching form 1... $FORM_COUNT"
        FORM_HTML=$(grep_form_by_order "$PAGE" $FORM_COUNT 2>/dev/null | break_html_lines_alt | replace $'\r' '')
        [ -z "$FORM_HTML" ] && log_debug "Another attempt to get form 1..." && \
            FORM_HTML=$(grep_form_by_order $(echo "$PAGE" | break_html_lines_alt) $FORM_COUNT 2>/dev/null)

        [ -z "$FORM_HTML" ] && log_error "Cannot find first step form" && return $ERR_FATAL
        ((FORM_COUNT++))

        # imhuman for played.to, youwatch.org
        if ! match "$FORM_STD_METHOD_F\|imhuman" "$FORM_HTML"; then
            continue
        fi

        FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_OP")
    done
    FORM_OP="$FORM_STD_OP=$FORM_OP"

    FORM_ID="$FORM_STD_ID="$(echo "$FORM_HTML" | parse_form_input_by_name "$FORM_STD_ID") || return
    FORM_USR="$FORM_STD_USR="$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_USR")
    FORM_FNAME="$FORM_STD_FNAME="$(echo "$FORM_HTML" | parse_form_input_by_name "$FORM_STD_FNAME") || return
    FORM_REFERER="$FORM_STD_REFERER="$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_REFERER")

    # Rare, but some hosters verify this hash on the first form
    FORM_HASH=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_HASH")
    [ -n "$FORM_HASH" ] && FORM_HASH="-d $FORM_STD_HASH=$FORM_HASH"

    if ! match "$FORM_STD_METHOD_F" "$FORM_HTML"; then
        # played.to, youwatch.org maybe more
        FORM_STD_METHOD_F='imhuman'
    fi

    FORM_METHOD_F=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_METHOD_F")
    if [ -z "$FORM_METHOD_F" ]; then
        FORM_METHOD_F=$(echo "$FORM_HTML" | parse_attr \
            "<[Bb][Uu][Tt][Tt][Oo][Nn][^>]*name=[\"']\?$FORM_STD_METHOD_F[\"']\?[[:space:]/>]" \
            'value') || return
    fi
    FORM_METHOD_F="$FORM_STD_METHOD_F=$FORM_METHOD_F"

    if [ "$#" -gt 8 ]; then
        for ADD in "${@:9}"; do
            if ! match '=' "$ADD"; then
                FORM_ADD=$FORM_ADD" -d $ADD="$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$ADD")
            else
                FORM_ADD=$FORM_ADD" -d $ADD"
            fi
        done
    fi

    echo "$FORM_FNAME"
    echo "$FORM_OP"
    echo "$FORM_ID"
    echo "$FORM_USR"
    echo "$FORM_REFERER"
    echo "$FORM_HASH"
    echo "$FORM_METHOD_F"
    echo "$FORM_ADD"
}

# Parse second step form (download)
#  Main download link genereation step. Captchas and timers are usually placed inside or
#  not far away from the main form.
# $1: (X)HTML page data
# $2-10:  (optional) custom form field names
# $11-... (optional) additional form fields (for custom callbacks)
# stdout: form data prepaired for cURL
#         "name=value" for mandatory and "-d name=value" for optional or sparse fields
xfilesharing_dl_parse_form2_generic() {
    local -r PAGE=$1
    local -r FORM_STD_NAME=${2:-'F1'}
    local -r FORM_STD_OP=${3:-'op'}
    local -r FORM_STD_ID=${4:-'id'}
    local -r FORM_STD_RAND=${5:-'rand'}
    local -r FORM_STD_REFERER=${6:-'referer'}
    local -r FORM_STD_METHOD_F=${7:-'method_free'}
    local -r FORM_STD_METHOD_P=${8:-'method_premium'}
    local -r FORM_STD_DD=${9:-'down_direct'}
    local -r FORM_STD_FNAME=${10:-'fname'}
    local FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_REFERER FORM_METHOD_F FORM_METHOD_P FORM_DD FORM_FNAME FORM_ADD

    if ! match "value=[\"']\?download2[\"']\?" "$PAGE"; then
        log_error 'Second form not found. Unexpected content.'
        return $ERR_FATAL
    fi

    log_debug 'Searching form 2...'
    FORM_HTML=$(grep_form_by_name "$PAGE" "$FORM_STD_NAME" 2>/dev/null | break_html_lines_alt | replace $'\r' '')
    [ -z "$FORM_HTML" ] && log_debug "Another attempt to get form 2..." && \
        FORM_HTML=$(grep_form_by_name $(echo "$PAGE" | break_html_lines_alt | replace $'\r' '') "$FORM_STD_NAME" 2>/dev/null)

    if [ -z "$FORM_HTML" ]; then
        log_error "Second form not found."
        return $ERR_FATAL
    fi

    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_OP") || return
    if [ -n "$FORM_OP" ]; then
        FORM_OP="$FORM_STD_OP=$FORM_OP"

    # Some XF mod special, part 1/3 (dozen of sites use this mod)
    else
        FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'act') || return
        FORM_OP="act=$FORM_OP"
    fi

    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_ID")
    if match 'download2' "$FORM_OP" && [ -z "$FORM_ID" ]; then
        log_error "Most probably file is deleted."
        return $ERR_LINK_DEAD
    fi
    FORM_ID="$FORM_STD_ID=$FORM_ID"

    FORM_RAND="$FORM_STD_RAND="$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_RAND")
    FORM_REFERER="$FORM_STD_REFERER="$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_REFERER")
    FORM_METHOD_F="$FORM_STD_METHOD_F="$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_METHOD_F")
    FORM_METHOD_P="$FORM_STD_METHOD_P="$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_METHOD_P")

    if match "$FORM_STD_DD" "$FORM_HTML"; then
        FORM_DD="-d $FORM_STD_DD=1"
    elif match 'down_script' "$FORM_HTML"; then
        FORM_DD='-d down_script=1'
    fi

    if match "<input[^>]*name[[:space:]]*=[[:space:]]*['\"]\?password['\"]\?" "$FORM_HTML"; then
        log_debug 'File is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
            FORM_PASSWORD="-d password=$LINK_PASSWORD"
        else
            FORM_PASSWORD="-d password=$LINK_PASSWORD"
        fi
    fi

    # Some XF mod special, part 2/3 (other sites may put this into second form, which is very handy)
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$FORM_STD_FNAME")
    if [ -n "$FORM_FNAME" ]; then
        FORM_FNAME=" -d $FORM_STD_FNAME=$FORM_FNAME"
    fi

    if [ "$#" -gt 10 ]; then
        for ADD in "${@:11}"; do
            if ! match '=' "$a"; then
                FORM_ADD=$FORM_ADD" -d $ADD="$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$ADD")
            else
                FORM_ADD=$FORM_ADD" -d $ADD"
            fi
        done
    fi

    echo "$FORM_FNAME"
    echo "$FORM_OP"
    echo "$FORM_ID"
    echo "$FORM_RAND"
    echo "$FORM_REFERER"
    echo "$FORM_METHOD_F"
    echo "$FORM_METHOD_P"
    echo "$FORM_DD"
    echo "$FORM_PASSWORD"
    echo "$FORM_ADD"
}

# Parse final link (download)
#  Extract or decrypt the final link from page returned by second step link generation form.
# $1: (X)HTML page data
# $2: (optional) file name
#     May be useful to find actual download link
# stdout: download URL
#         file name (optional)
xfilesharing_dl_parse_final_link_generic() {
    local PAGE=$1
    local FILE_NAME=$2

    local LOCATION FILE_URL

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)

    # Generic final link parser
    if [ -n "$LOCATION" ]; then
        log_debug 'Link from redirect.'

        if ! match '/d/\|/files/\|/dl/\|dl\.cgi\|/cgi-bin/' "$LOCATION"; then
            log_debug 'Strange download link.'
        fi

        FILE_URL="$LOCATION"
    else
        local RE_URL="[^'^\"^[:space:]^>^<^\[]"
        local RE_DLOC='/d/\|/files/\|/dl/\|dl\.cgi'
        local TRY
        local PAGE_BREAK=$(echo "$PAGE" | break_html_lines_alt)

        for TRY in 1 2; do
            [ $TRY = 2 ] && RE_DLOC='/cgi-bin/' && log_debug 'Trying other needle...'

            [ -n "$FILE_NAME" ] && FILE_URL=$(echo "$PAGE_BREAK" | parse_attr_quiet \
                "\($RE_DLOC\)$RE_URL*$FILE_NAME" href) \
                && log_debug 'Searching for link... method 1'

            [ -z "$FILE_URL" ] && FILE_URL=$(echo "$PAGE_BREAK" | parse_all_attr_quiet \
                "$RE_DLOC" href | last_line) \
                && log_debug 'Searching for link... method 2'

            [ -z "$FILE_URL" ] && FILE_URL=$(echo "$PAGE_BREAK" | parse_all_quiet \
                "$RE_DLOC" \
                "\(https\?://$RE_URL\+\($RE_DLOC\)$RE_URL\+\)" | last_line) \
                && log_debug 'Searching for link... method 3'

            [ -n "$FILE_URL" ] && break
        done

        [ -z "$FILE_URL" -a -n "$FILE_NAME" ] && FILE_URL=$(echo "$PAGE_BREAK" | parse_quiet \
            "http://.*$FILE_NAME" \
            "\(http://$RE_URL\+$FILE_NAME$RE_URL*\)") \
            && log_debug 'Searching for link... method 4'
    fi

    # hulkload, queenshare adflying links
    if match '^http://adf\.ly/.*http://' "$FILE_URL"; then
        log_debug 'Aflyed link detected.'
        FILE_URL=$(echo "$FILE_URL" | parse . '^http://adf\.ly/.*\(http://.*\)$')
    fi

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Commit first step (download)
#  Process all form data into cURL request. Sometimes site can add some additional
#  steps to get the download link, this is the right place to process such things.
# $1: cookie file
# $2: main URL (used as form action)
# $3: form data returned by parse function
# stdout: (X)HTML page data
xfilesharing_dl_commit_step1_generic() {
    local -r COOKIE_FILE=$1
    local -r FORM_ACTION=$2
    local -r FORM_DATA=$3

    local FORM_OP FORM_ID FORM_USR FORM_FNAME FORM_REFERER FORM_HASH FORM_METHOD_F FORM_ADD

    IFS=
    {
    read -r FORM_FNAME
    read -r FORM_OP
    read -r FORM_ID
    read -r FORM_USR
    read -r FORM_REFERER
    read -r FORM_HASH
    read -r FORM_METHOD_F
    read -r FORM_ADD
    } <<<"$FORM_DATA"
    unset IFS

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -d "$FORM_OP" \
        -d "$FORM_USR" \
        -d "$FORM_ID" \
        --data-urlencode "$FORM_FNAME" \
        -d "$FORM_REFERER" \
        -d "$FORM_METHOD_F" \
        $FORM_HASH \
        $FORM_ADD \
        "$FORM_ACTION" | \
        strip_html_comments) || return

    echo "$PAGE"
}

# Commit second step (download)
#  Process all form data into cURL request. Final step before final link appears.
#  Some sites may return file right after submition of second form, or may require some
#  EXTRA stuff for cURL (like referrer). In such cases this function must return
#  final URL by itself.
# $1: cookie file
# $2: main URL (used as form action)
# $3: form data returned by parse function
# $4: (optional) captcha data
# stdout: (X)HTML page data
xfilesharing_dl_commit_step2_generic() {
    local -r COOKIE_FILE=$1
    local -r FORM_ACTION=$2
    local -r FORM_DATA=$3
    local -r FORM_CAPTCHA=$4

    local PAGE FORM_FNAME FORM_OP FORM_ID FORM_RAND FORM_REFERER FORM_METHOD_F FORM_METHOD_P FORM_DD FORM_PASSWORD FORM_ADD
    local EXTRA

    IFS=
    {
    read -r FORM_FNAME;
    read -r FORM_OP;
    read -r FORM_ID;
    read -r FORM_RAND;
    read -r FORM_REFERER;
    read -r FORM_METHOD_F;
    read -r FORM_METHOD_P;
    read -r FORM_DD;
    read -r FORM_PASSWORD;
    read -r FORM_ADD;
    } <<<"$FORM_DATA"
    unset IFS

    # Some XF mod special
    if [ 'act=download2' = "$FORM_OP" ] && [ -n "$FORM_FNAME" ]; then
        log_debug 'XF download-after-post mod detected.'

        EXTRA="MODULE_XFILESHARING_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=( \
            -d \"$FORM_OP\" \
            -d \"$FORM_ID\" \
            $FORM_FNAME \
            -d \"$FORM_RAND\" \
            $FORM_CAPTCHA \
            $FORM_ADD )"

        FORM_FNAME=$(echo "$FORM_FNAME" | parse . "=\(.*\)$")

        echo "$FORM_ACTION"
        echo "$FORM_FNAME"
        echo "$EXTRA"
        return 0
    fi

    PAGE=$(curl -i -b "$COOKIE_FILE" -b 'lang=english' \
        -d "$FORM_OP" \
        -d "$FORM_ID" \
        -d "$FORM_RAND" \
        -d "$FORM_REFERER" \
        -d "$FORM_METHOD_F" \
        -d "$FORM_METHOD_P" \
        $FORM_CAPTCHA \
        $FORM_PASSWORD \
        $FORM_DD \
        $FORM_FNAME \
        $FORM_ADD \
        "$FORM_ACTION") || return

    echo "$PAGE"
}

# Parse streaming media URL (download)
#  Must return 1 if no media found and 0 otherwise. Players are placed in random places,
#  so this function searches for video data after and before each step.
# $1: (X)HTML page data
# $2: url of page with player (required by some rtmp)
# $3: (optional) filename
# stdout: download URL (or RTMP link with parameters)
#         file name (optional)
xfilesharing_dl_parse_streaming_generic () {
    local PAGE=$1
    local -r URL=$2
    local -r FILE_NAME=$3
    local JS_PLAYER_FOUND=0
    local RE_PLAYER="jwplayer([\"']flvplayer[\"']).setup\|new SWFObject.*player\|DivXBrowserPlugin\|StrobeMediaPlayback.swf"

    if match '<script[^>]*>eval(function(p,a,c,k,e,d)' "$PAGE"; then
        log_debug 'Found some packed script (type 1)...'

        detect_javascript || return

        SCRIPTS=$(echo "$PAGE" | parse_all "<script[^>]*>eval(function(p,a,c,k,e,d)" "<script[^>]*>\(eval.*\)$")

        while read -r JS; do
            JS=$(xfilesharing_unpack_js "$JS")

            if match "$RE_PLAYER" "$JS"; then
                log_debug "Found some player code in packed script (type 1)."
                JS_PLAYER_FOUND=1
                PAGE="$JS"
                break
            fi

            [ -z "$FILE_URL" ] && log_debug 'Checking another script...'
        done <<< "$SCRIPTS"

        [ -z JS_PLAYER_FOUND ] && log_debug 'Nothing found in packed script (type 1).'
    fi

    # www.zinwa.com special
    if match 'function decodejs(instr,icount)' "$PAGE"; then
        log_debug 'Found some packed script (type 2)...'

        detect_javascript || return

        SCRIPT_N=1
        SCRIPTS=$(echo "$PAGE" | parse_all '<script' '^\(.*\)$' 1)

        while read JS; do
            if match 'function decodejs(instr,icount)' "$JS"; then
                break
            fi
            (( SCRIPT_N++ ))
        done <<< "$SCRIPTS"

        JS=$(grep_script_by_order "$PAGE" $SCRIPT_N | delete_first_line | delete_last_line | replace $'\r' '' | replace $'\n' '')
        JS=$(xfilesharing_unpack_js "$JS")

        if matchi "$RE_PLAYER" "$JS"; then
            log_debug "Found some player code in packed script (type 2)."
            PAGE="$JS"
        else
            log_debug 'Nothing found in packed script (type 2).'
        fi
    fi

    if matchi "jwplayer([\"']flvplayer[\"']).setup\|new SWFObject.*player" "$PAGE"; then
        if match 'streamer.*rtmp' "$PAGE"; then
            RTMP_BASE=$(echo "$PAGE" | parse 'streamer.*rtmp' "[\"']\?streamer[\"']\?[[:space:]]*[,\:][[:space:]]*[\"']\?\(rtmp[^'^\"^)]\+\)")
            RTMP_PLAYPATH=$(echo "$PAGE" | parse 'file' "[\"']\?file[\"']\?[[:space:]]*[,\:][[:space:]]*[\"']\?\([^'^\"^)]\+\)")

            FILE_URL="$RTMP_BASE playpath=$RTMP_PLAYPATH"

        # videopremium.tv special
        elif match 'file":"rtmp' "$PAGE"; then
            RTMP_SRC=$(echo "$PAGE" | parse 'file":"rtmp' '"file":"\(rtmp[^"]\+\)')
            RTMP_SWF=$(echo "$PAGE" | parse 'new swfobject.embedSWF("' 'new swfobject.embedSWF("\([^"]\+\)')

            RTMP_PLAYPATH=$(echo "$RTMP_SRC" | parse . '^.*/\([^/]*\)$')
            RTMP_BASE=$(echo "$RTMP_SRC" | parse . '^\(.*\)/[^/]*$')

            FILE_URL="$RTMP_BASE pageUrl=$URL playpath=$RTMP_PLAYPATH swfUrl=$RTMP_SWF"
        else
            FILE_URL=$(echo "$PAGE" | parse 'file.*http' "[\"']\?file[\"']\?[[:space:]]*[,\:][[:space:]]*[\"']\?\(http[^'^\"^)]\+\)")
        fi

    # www.donevideo.com special
    elif match '<object[^>]*DivXBrowserPlugin' "$PAGE"; then
        FILE_URL=$(echo "$PAGE" | parse '<object[^>]*DivXBrowserPlugin' 'id="np_vid"[^>]*src="\([^"]\+\)')

    # www.lovevideo.tv special
    elif match 'StrobeMediaPlayback.swf' "$PAGE"; then
        # rtmp://50.7.69.178/vod000027/ey5ozfhq448b.flv?e=1378429062&st=f-o_ItdghTPRSnILtjgnng
        # "rtmp://50.7.69.178/vod000027 pageUrl=http://www.lovevideo.tv/4fnfwqtu1typ playpath=ey5ozfhq448b.flv?e=1378464032&st=Bg1WAlpO3wr9HRkteAy4ng"
        RTMP_SRC=$(echo "$PAGE" | parse 'StrobeMediaPlayback.swf' "value='src=\(rtmp[^&]\+\)" | uri_decode | replace '%3F' '?')
        RTMP_PLAYPATH=$(echo "$RTMP_SRC" | parse . '^.*/\([^/]*\)$')
        RTMP_BASE=$(echo "$RTMP_SRC" | parse . '^\(.*\)/[^/]*$')

        # Need to add some exception for rtmp links
        FILE_URL="$RTMP_BASE pageUrl=$URL playpath=$RTMP_PLAYPATH"
    fi

    if [ -n "$FILE_URL" ]; then
        echo "$FILE_URL"
        [ -n "$FILE_NAME" ] && echo "$FILE_NAME"
        return 0
    fi

    return 1
}

# Parse image URL for imagehostings (download)
#  Usually images are placed right on the first page, so this function is called first.
# $1: (X)HTML page data
# stdout: download URL
#         file name (optional)
xfilesharing_dl_parse_imagehosting_generic() {
    local -r PAGE=$1

    RE_IMG="<img[^>]*src=[^>]*\(/files/\|/i/\)[^'\"[:space:]>]*\(t(_\|[^_])\|[^t]\)\."
    if match "$RE_IMG" "$PAGE"; then
        IMG_URL=$(echo "$PAGE" | parse_attr_quiet "$RE_IMG" 'src')
        IMG_ALT=$(echo "$PAGE" | parse_attr_quiet "$IMG_URL" 'alt')
        IMG_TITLE=$(echo "$PAGE" | parse_tag_quiet '<[Tt]itle>' '[Tt]itle')
        IMG_ID=$(echo "$URL" | parse_quiet . '[^/]/\([[:alnum:]]\{12\}\)\(/\|$\)')
        # Ignore video thumbnails
        if [ -n "$IMG_URL" ]; then
            if ( [ -n "$IMG_ALT" ] && match "$IMG_ALT" "$IMG_TITLE" ) || \
            match "$IMG_ID" "$IMG_URL"; then
                log_debug 'Image hosting detected'

                echo "$IMG_URL"
                [ -n "$IMG_ALT" ] && echo "$IMG_ALT"
                return 0
            fi
        fi
    fi

    return 1
}

# Parse contdown timer data (download)
# $1: (X)HTML page data
# stdout: time to wait
xfilesharing_dl_parse_countdown_generic () {
    local -r PAGE=$1
    local WAIT_TIME PAGE_UNBREAK

    if match '"countdown_str"' "$PAGE"; then
        WAIT_TIME=$(echo "$PAGE" | parse_quiet 'countdown_str' \
            'countdown_str.*<span[^>]*id="[[:alnum:]]\{6\}">[[:space:]]*\([0-9]\+\)[[:space:]]*<') \
            && log_debug "Seraching countdown timer... 1"
        [ -z "$WAIT_TIME" ] && WAIT_TIME=$(echo "$PAGE" | parse_quiet '<span id="[[:alnum:]]\{6\}">' \
            '<span id="[[:alnum:]]\{6\}">[[:space:]]*\([0-9]\+\)[[:space:]]*<') \
            && log_debug "Seraching countdown timer... 2"
        [ -z "$WAIT_TIME" ] && WAIT_TIME=$(echo "$PAGE" | parse_quiet 'Wait.*second' \
            'Wait.*>[[:space:]]*\([0-9]\+\)[[:space:]]*<.*second') \
            && log_debug "Seraching countdown timer... 3"
        [ -z "$WAIT_TIME" ] && WAIT_TIME=$(echo "$PAGE" | parse_quiet 'countdown_str' \
            'countdown_str.*<span[^>]*id="[[:alnum:]]\+"[^>]*>[[:space:]]*\([0-9]\+\)[[:space:]]*<') \
            && log_debug "Seraching countdown timer... 4"

        [ -z "$WAIT_TIME" ] && PAGE_UNBREAK=$(echo "$PAGE" | replace $'\n' '')
        [ -z "$WAIT_TIME" ] && WAIT_TIME=$(echo "$PAGE_UNBREAK" | parse_quiet 'countdown_str' \
            'countdown_str.*<span[^>]*id="[[:alnum:]]\{6\}"[^>]*>[[:space:]]*\([0-9]\+\)[[:space:]]*<') \
            && log_debug "Seraching countdown timer... 5"
        [ -z "$WAIT_TIME" ] && WAIT_TIME=$(echo "$PAGE_UNBREAK" | parse_quiet 'countdown_str' \
            'countdown_str.*<span[^>]*id="[[:alnum:]]\+"[^>]*>[[:space:]]*\([0-9]\+\)[[:space:]]*<') \
            && log_debug "Seraching countdown timer... 6"

        [ -z "$WAIT_TIME" ] && log_error "Cannot locate countdown timer." && return $ERR_FATAL

        # Wait some more to avoid "Skipped countdown" error
        [ -n "$WAIT_TIME" ] && ((WAIT_TIME++))

        echo "$WAIT_TIME"
    fi
}

# Check if account has enough space (upload)
# $1: cookie file (logged into account)
# $2: base URL
# stdout: space used (XXX Mb/Kb/Gb)
#         space limit
xfilesharing_ul_get_space_data_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE SPACE_USED SPACE_LIMIT

    PAGE=$(curl -b 'lang=english' -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/" | strip_html_comments) || return

    if ! match 'Used space.*of\|[0-9.]\+[[:space:]]*of[[:space:]]*[0-9.]\+[[:space:]]*GB[[:space:]]*Used' "$PAGE"; then
        log_debug 'No space information found.'
        return 0
    fi

    if match '[0-9.]\+[[:space:]]*of[[:space:]]*[0-9.]\+[[:space:]]*GB[[:space:]]*Used' "$PAGE"; then
        # XXX Kb of XXX GB
        SPACE_USED=$(echo "$PAGE" | parse_quiet '[0-9.]\+[[:space:]]*of[[:space:]]*[0-9.]\+[[:space:]]*[KMGBb]\+\?[[:space:]]*Used' \
            '>\([0-9.]\+[[:space:]]*[KMGBb]\+\?\) of ')
        if [ -z "$SPACE_USED" ]; then
            SPACE_USED=$(echo "$PAGE" | parse '[0-9.]\+[[:space:]]*of[[:space:]]*[0-9.]\+[[:space:]]*[KMGBb]\+\?[[:space:]]*Used' \
                ' \([0-9.]\+[[:space:]]*[KMGBb]\+\?\) of ') || return
        fi

        SPACE_LIMIT=$(echo "$PAGE" | parse '[0-9.]\+[[:space:]]*of[[:space:]]*[0-9.]\+[[:space:]]*[KMGBb]\+\?[[:space:]]*Used' \
            'of \([0-9.]\+[[:space:]]*[KMGBb]\+\)') || return
    else
        # XXX Kb of XXX GB
        SPACE_USED=$(echo "$PAGE" | parse_quiet 'Used space' \
            '>\([0-9.]\+[[:space:]]*[KMGBb]\+\?\) of ')
        if [ -z "$SPACE_USED" ]; then
            SPACE_USED=$(echo "$PAGE" | parse 'Used space' \
                ' \([0-9.]\+[[:space:]]*[KMGBb]\+\?\) of ') || return
        fi

        SPACE_LIMIT=$(echo "$PAGE" | parse 'Used space' \
            'of \([0-9.]\+[[:space:]]*[KMGBb]\+\)') || return
    fi

    # played.to speedvid
    if match '^[0-9.]\+$' "$SPACE_USED"; then
        SPACE_MEASURE=$(echo "$SPACE_LIMIT" | parse . '[[:space:]]\([KMGBb]\+\)$') || return
        SPACE_USED="$SPACE_USED $SPACE_MEASURE"
        log_debug "Common space measure: '$SPACE_MEASURE'"
    fi

    echo "$SPACE_USED"
    echo "$SPACE_LIMIT"
}

# Get folder data from account page (upload)
# stdout: folder ID
#         (optional) token, used in move file request
#         (optional) folder move command
xfilesharing_ul_get_folder_data_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r NAME=$3

    local PAGE FORM FOLDERS FOLDER_ID TOKEN COMMAND

    # Special treatment for root folder (always uses ID "0")
    #if [ "$NAME" = '/' ]; then
    #    echo 0
    #    return 0
    #fi

    # exclusivefaile.com upcenter.com - move file broken
    # free-uploading.com - create folder glitch
    if match 'exclusivefaile\.com\|free-uploading\.com\|upcenter\.com' "$BASE_URL"; then
        echo 0
        return 0
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    # Some XF mod has broken folder functionality
    #  caiuaqui 1000shared up4s 4upe
    if match '<option value="|">New folder...</option>' "$PAGE"; then
        log_debug 'Broken folder mod detected.'
        echo 0
        return 0
    fi

    if match "<[Ss]elect[^>]*to_folder[^[:alnum:]_]" "$PAGE"; then
        SELECT_N=1
        SELECTS=$(echo "$PAGE" | parse_all '<[Ss]elect' '^\(.*\)$')

        while read -r LINE; do
            match '<[Ss]elect[^>]*to_folder[^[:alnum:]_]' "$LINE" && break
            (( SELECT_N++ ))
        done <<< "$SELECTS"

        # <option value="ID">&nbsp;Folder Name</option>
        # Note: - Site uses "&nbsp;" to indent sub folders
        FORM=$(grep_block_by_order '[Ss]elect' "$PAGE" "$SELECT_N" | \
            replace $'\r' '' | replace $'\n' '' | \
            replace '<option' $'\n<option' | replace '</option>' $'</option>\n' | \
            replace '&nbsp;' '')
    fi

    if match '<option' "$FORM"; then
        # Note: - First entry is label "Move files to folder"
        #       - Second entry is root folder "/"
        FOLDERS=$(echo "$FORM" | parse_all_tag 'option' | delete_first_line 2 | strip) || return

        if match "^$NAME$" "$FOLDERS"; then
            FOLDER_ID=$(echo "$FORM" | parse_attr "<option[^>]*>[[:space:]]*$NAME[[:space:]]*</option>" 'value') || return
        fi

    elif match '<a[^>]*my_files&amp;fld_id=' "$PAGE"; then
        FORM=$(echo "$PAGE" | replace $'\r' '' | replace $'\n' '' | \
            replace '<a' $'\n<a' | replace '</a>' $'</a>\n' | \
            replace '&nbsp;' '')

        # <a href="/?op=my_files&amp;fld_id=ID"><b>Folder Name</b></a>
        # absent if no folders created
        FOLDERS=$(echo "$FORM" | parse_all_tag_quiet '<a[^>]*my_files&amp;fld_id=' 'a' | strip)
        if match '>' "$FOLDERS"; then
            FOLDERS=$(echo "$FOLDERS" | parse_all_quiet . '>\([^<]\+\)' | strip)
        fi

        if match "^$NAME$" "$FOLDERS"; then
            FOLDER_ID=$(echo "$FORM" | parse "<a[^>]*fld_id=.*>[[:space:]]*$NAME[[:space:]]*<" 'fld_id=\([0-9]\+\)') || return
        fi
    fi

    if [ -n "$FOLDER_ID" ]; then
        TOKEN=$(echo "$PAGE" | parse_form_input_by_name_quiet 'token')

        COMMAND=$(echo "$PAGE" | parse_form_input_by_name_quiet 'to_folder_move')
        if [ -z "$COMMAND" ]; then
            COMMAND=$(echo "$PAGE" | parse_form_input_by_name_quiet 'file_move')
            [ -n "$COMMAND" ] && COMMAND="file_move=$COMMAND"
        else
            COMMAND="to_folder_move=$COMMAND"
        fi

        log_debug "Folder ID: '$FOLDER_ID'"
        [ -n "$TOKEN" ] && log_debug "Token: '$TOKEN'"

        echo "$FOLDER_ID"
        echo "$TOKEN"
        echo "$COMMAND"
    fi

    return 0
}

# Create folder (upload)
# $1: cookie file (logged into account)
# $2: base URL
# $3: folder name
# $?: 0 for success
xfilesharing_ul_create_folder_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r NAME=$3

    local PAGE LOCATION

    PAGE=$(curl -b "$COOKIE_FILE" -i \
        -H 'Expect: ' \
        -d 'op=my_files' \
        -d "fld_id=0" \
        -d "create_new_folder=$NAME" \
        "$BASE_URL/") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)
    if match '?op=my_files' "$LOCATION"; then
        log_debug 'Folder created.'
    else
        log_error 'Could not create folder.'
    fi

    return 0
}

# Get last uploaded file ID from user page (upload)
# $1: cookie file (logged into account)
# $2: base URL
# stdout: file ID
xfilesharing_ul_get_file_id_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE FILE_ID

    log_debug 'Trying to get file ID form user page...'

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/" | break_html_lines) || return

    FILE_ID=$(parse_form_input_by_name_quiet 'file_id' <<< "$PAGE")
    if [ -z "$FILE_ID" ]; then
        log_error 'Cannot get file ID from user page.'
        return $ERR_FATAL
    else
        echo "$FILE_ID"
        return 0
    fi
}

# Parse form or other data (upload)
# $1: (X)HTML page data
# stdout: form data
xfilesharing_ul_parse_data_generic() {
    local -r PAGE=$1

    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_TMP_SRV

    if match 'no servers available for upload at the moment' "$PAGE"; then
        log_error 'No servers available for upload at the moment. Try again later.'
        return $ERR_FATAL
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'file' 2>/dev/null | break_html_lines_alt)
    if [ -z "$FORM_HTML" ]; then
        FORM_NAME=$(echo "$PAGE" | parse_quiet '<form[^>]*/cgi-bin[^>]*upload.cgi' "<form[^>]*name[[:space:]]*=[[:space:]]*[\"']\?\([^'\">]\+\)[\"']\?")
        if [ -n "$FORM_NAME" ]; then
            log_debug 'Found upload form by action.'
            FORM_HTML=$(grep_form_by_name "$PAGE" "$FORM_NAME" | break_html_lines_alt) || return
        fi
    fi

    if [ -z "$FORM_HTML" ] && match 'up_flash.cgi' "$PAGE"; then
        log_debug 'Using flash uploader.'

        FL_URL=$(echo "$PAGE" | parse 'script.*up_flash.cgi' "script['\"]\?[[:space:]]*:[[:space:]]*['\"]\([^'\",]\+\)") || return
        FL_FILEEXT=$(echo "$PAGE" | parse_quiet 'fileExt' "fileExt['\"]\?[[:space:]]*:[[:space:]]*['\"]\([^'\",]\+\)")
        FL_SESS=$(echo "$PAGE" | parse_quiet 'scriptData.*sess_id' "sess_id['\"]\?[[:space:]]*:[[:space:]]*['\"]\([^'\"]\+\)")

        echo "$FL_URL"
        echo "$FL_FILEEXT"
        echo "$FL_SESS"

        return 0

    elif [ -z "$FORM_HTML" ]; then
        log_error 'Wrong upload page or anonymous uploads not allowed.'
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return

    FORM_USER_TYPE=$(echo "$PAGE" | parse_quiet 'var[[:space:]]*utype' "utype['\"]\?[[:space:]]*=[[:space:]]*['\"]\?\([^'\";]\+\)['\"]\?")

    if [ -n "$FORM_USER_TYPE" ]; then
        log_debug "User type: '$FORM_USER_TYPE'"
    else
        if [ -n "$AUTH" ]; then
            FORM_USER_TYPE='reg'
        else
            FORM_USER_TYPE='anon'
        fi

        log_debug "User type not found."
    fi

    # Will be empty on anon upload
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id')
    [ -n "$FORM_SESS" ] && FORM_SESS="-F sess_id=$FORM_SESS"

    FORM_SRV_TMP=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'srv_tmp_url')
    [ -n "$FORM_SRV_TMP" ] && FORM_SRV_TMP="-F srv_tmp_url=$FORM_SRV_TMP"

    FORM_SRV_ID=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'srv_id')
    [ -n "$FORM_SRV_ID" ] && FORM_SRV_ID="-F srv_id=$FORM_SRV_ID"

    FORM_DISK_ID=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'disk_id')
    if [ -n "$FORM_DISK_ID" ]; then
        FORM_DISK_ID_URL="&disk_id=$FORM_DISK_ID"
        FORM_DISK_ID="-F disk_id=$FORM_DISK_ID"
    fi

    FORM_SUBMIT_BTN=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'submit_btn')

    FORM_FILE_FIELD=$(echo "$FORM_HTML" | parse_attr_quiet "<input[^>]*type[[:space:]]*=[[:space:]]*['\"]\?file['\"]\?" 'name')
    if [ -z "$FORM_FILE_FIELD" ] || [ "$FORM_FILE_FIELD" = "file_1" ]; then
        FORM_FILE_FIELD='file_0'
    else
        log_debug "File field: '$FORM_FILE_FIELD'"
    fi

    if match "<input[^>]*name[[:space:]]*=[[:space:]]*['\"]\?url_1['\"]\?" "$PAGE"; then
        FORM_REMOTE_URL_FIELD="url_1"
    else
        FORM_REMOTE_URL_FIELD="url_mass"
    fi

    if [ "$#" -gt 1 ]; then
        for ADD in "${@:2}"; do
            if ! match '=' "$ADD"; then
                FORM_ADD=$FORM_ADD" -F $ADD="$(echo "$FORM_HTML" | parse_form_input_by_name_quiet "$ADD")
            else
                FORM_ADD=$FORM_ADD" -F $ADD"
            fi
        done
    fi

    echo "$FORM_ACTION"
    echo "$FORM_USER_TYPE"
    echo "$FORM_SESS"
    echo "$FORM_SRV_TMP"
    echo "$FORM_SRV_ID"
    echo "$FORM_DISK_ID"
    echo "$FORM_DISK_ID_URL"
    echo "$FORM_SUBMIT_BTN"
    echo "$FORM_FILE_FIELD"
    echo "$FORM_REMOTE_URL_FIELD"
    echo "$FORM_ADD"
}

# Main step (upload)
# $1: cookie file
# $2: base URL
# $3: input file (with full path) or remote URL
# $4: remote filename
# $5: form data
# stdout: (X)HTML page data
xfilesharing_ul_commit_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$(basename_url "$2")
    local -r FILE=$3
    local -r DEST_FILE=$4
    local -r FORM_DATA=$5

    local FORM_HTML FORM_SESS FORM_SRV_TMP FORM_SRV_ID FORM_DISK_ID FORM_DISK_ID_URL FORM_SUBMIT_BTN FILE_FIELD FORM_REMOTE_URL_FIELD FORM_ADD

    if match 'up_flash.cgi' "$FORM_DATA"; then
        if match_remote_url "$FILE"; then
            log_error 'Remote uploads not supported by flash uploader.'
            return $ERR_FATAL
        fi

        IFS=
        {
        read -r FORM_ACTION
        read -r FORM_FILEEXT
        read -r FORM_SESS
        } <<<"$FORM_DATA"
        unset IFS

        if [[ "$FORM_ACTION" = $(basename_url "$FORM_ACTION") ]]; then
            FORM_ACTION="$BASE_URL$FORM_ACTION"
        fi

        [ -n "$FORM_FILEEXT" ] && FORM_FILEEXT="-F fileext=$FORM_FILEEXT"
        [ -n "$FORM_SESS" ] && FORM_SESS="-F sess_id=$FORM_SESS"

        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -H 'Expect: ' \
            -F "Filename=$DESTFILE" \
            -F 'folder=/' \
            $FORM_FILEEXT \
            $FORM_SESS \
            -F "Filedata=@$FILE;filename=$DESTFILE" \
            -F 'Upload=Submit Query' \
            "$FORM_ACTION") || return

        echo "$PAGE"
        return 0
    fi

    IFS=
    {
    read -r FORM_ACTION
    read -r FORM_USER_TYPE
    read -r FORM_SESS
    read -r FORM_SRV_TMP
    read -r FORM_SRV_ID
    read -r FORM_DISK_ID
    read -r FORM_DISK_ID_URL
    read -r FORM_SUBMIT_BTN
    read -r FORM_FILE_FIELD
    read -r FORM_REMOTE_URL_FIELD
    read -r FORM_ADD
    } <<<"$FORM_DATA"
    unset IFS

    if [[ "$FORM_ACTION" = $(basename_url "$FORM_ACTION") ]]; then
        FORM_ACTION="$BASE_URL$FORM_ACTION"
    fi

    if [ -z "$PRIVATE_FILE" ]; then
        PUBLIC_FLAG=1
    else
        PUBLIC_FLAG=0
    fi

    # Initial js code:
    # for (var i = 0; i < 12; i++) UID += '' + Math.floor(Math.random() * 10);
    # form_action = form_action.split('?')[0] + '?upload_id=' + UID + '&js_on=1' + '&utype=' + utype + '&upload_type=' + upload_type;
    # upload_type: file, url
    # utype: anon, reg
    UPLOAD_ID=$(random d 12)

    # Upload remote file
    if match_remote_url "$FILE"; then
        # url_proxy	- http proxy
        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -i \
            -H 'Expect: ' \
            -F "upload_type=url" \
            $FORM_SESS \
            $FORM_SRV_TMP \
            $FORM_SRV_ID \
            $FORM_DISK_ID \
            -F "${FORM_REMOTE_URL_FIELD}=$FILE" \
            $FORM_TOEMAIL \
            $FORM_PASSWORD \
            -F "tos=1" \
            -F "submit_btn=$FORM_SUBMIT_BTN" \
            $FORM_ADD \
            "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${FORM_USER_TYPE}&upload_type=url$FORM_DISK_ID_URL" | \
            break_html_lines) || return

    # Upload local file
    else
        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -i \
            -H 'Expect: ' \
            -F 'upload_type=file' \
            $FORM_SESS \
            $FORM_SRV_TMP \
            $FORM_SRV_ID \
            $FORM_DISK_ID \
            -F "${FORM_FILE_FIELD}=@$FILE;filename=$DESTFILE" \
            --form-string "${FORM_FILE_FIELD}_descr=$DESCRIPTION" \
            -F "${FORM_FILE_FIELD}_public=$PUBLIC_FLAG" \
            --form-string "link_rcpt=$TOEMAIL" \
            --form-string "link_pass=$LINK_PASSWORD" \
            -F 'tos=1' \
            -F "submit_btn=$FORM_SUBMIT_BTN" \
            $FORM_ADD \
            "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${FORM_USER_TYPE}&upload_type=file$FORM_DISK_ID_URL" | \
            break_html_lines) || return
    fi

    echo "$PAGE"
}

# Parse result (upload)
# $1: (X)HTML page data
# stdout: upload result data
xfilesharing_ul_parse_result_generic() {
    local PAGE=$1

    local PAGE_BODY STATE OP FORM_LINK_RCPT FILE_CODE DEL_CODE
    local FORM_HTML RESPONSE ERROR FORM_ACTION

    RESPONSE=$(echo "$PAGE" | first_line)
    if match '^HTTP.*50[0-9]' "$RESPONSE"; then
        log_error 'Server Issues.'
        return $ERR_FATAL
    fi

    RESPONSE=$(echo "$PAGE" | last_line)
    if match '^<HTML></HTML>$' "$RESPONSE"; then
        log_error 'Server Issues. Empty response.'
        return $ERR_FATAL
    fi

    # Flash uploader result
    #  fp2hijbaodrx:fp2hijbaodrx:00002:file.rar:file_type
    #  or bad result status as single string

    PAGE_BODY="${PAGE#$'HTTP*\n\n'}"
    if match '^[[:alnum:]]\+:' "$RESPONSE"; then
        FILE_CODE=$(echo "$RESPONSE" | parse . '^\([[:alnum:]]\+\)')

        echo 'EDIT'
        echo "$FILE_CODE"
        return 0

    elif [ "${#PAGE_BODY}" = "${#RESPONSE}" ]; then
        echo "$RESPONSE"
        return 0
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1' 2>/dev/null)

    if [ -z "$FORM_HTML" ]; then
        ERROR=$(echo "$PAGE" | parse_quiet '[Ee][Rr][Rr][Oo][Rr]:' "[Ee][Rr][Rr][Oo][Rr]:[[:space:]]*\(.*\)')")
        if [ -n "$ERROR" ]; then
            if [ "$ERROR" = "You can\'t use remote URL upload" ]; then
                log_error "Remote uploads disabled or limited for your account type."
                return $ERR_LINK_NEED_PERMISSIONS
            else
                log_error "Remote error: '$ERROR'"
            fi
        else
            log_error 'Unexpected content.'
        fi

        return $ERR_FATAL
    fi

    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return

    # download-after-post mod special
    if match "<textarea name='url_mass'>" "$FORM_HTML"; then
        log_error 'This hosting does not support remote uploads.'
        return $ERR_FATAL
    elif match "<textarea name='status'>" "$FORM_HTML"; then
        FILE_CODE=$(echo "$FORM_HTML" | parse_tag "name=[\"']\?filename[\"']\?" 'textarea') || return
        STATE=$(echo "$FORM_HTML" | parse_tag "name=[\"']\?status[\"']\?" 'textarea') || return

        DEL_CODE=$(echo "$FORM_HTML" | parse_tag "name=[\"']\?del_id[\"']\?" 'textarea') || return
        FILE_NAME=$(echo "$FORM_HTML" | parse_tag "name=[\"']\?filename_original[\"']\?" 'textarea') || return

    else
        OP=$(echo "$FORM_HTML" | parse_tag "name=[\"']\?op[\"']\?" 'textarea') || return
        FILE_CODE=$(echo "$FORM_HTML" | parse_tag_quiet "name=[\"']\?fn[\"']\?" 'textarea')
        STATE=$(echo "$FORM_HTML" | parse_tag_quiet "name=[\"']\?st[\"']\?" 'textarea')

        FORM_LINK_RCPT=$(echo "$FORM_HTML" | parse_tag_quiet "name=[\"']\?link_rcpt[\"']\?" 'textarea')
        [ -n "$FORM_LINK_RCPT" ] && FORM_LINK_RCPT="--form-string link_rcpt=$FORM_LINK_RCPT"

        if [ -z "$FILE_CODE" ]; then
            log_error 'Upload failed. No file code received.'
            return $ERR_FATAL
        fi
    fi

    echo "$STATE"
    echo "$FILE_CODE"
    echo "$DEL_CODE"
    echo "$FILE_NAME"
    echo "$FORM_ACTION"
    echo "$OP"
    echo "$FORM_LINK_RCPT"
}

# Commit final step (upload)
#  Sometimes not required. Used to get final link page with delete code or file ID.
# $1: cookie file
# $2: base URL
# $3: upload result data (form data)
# stdout: (X)HTML page data
xfilesharing_ul_commit_result_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r FORM_DATA=$3

    local PAGE FILE_CODE DEL_CODE FORM_ACTION OP STATE FORM_LINK_RCPT FILE_NAME

    IFS=
    {
    read -r STATE
    read -r FILE_CODE
    read -r DEL_CODE
    read -r FILE_NAME
    read -r FORM_ACTION
    read -r OP
    read -r FORM_LINK_RCPT
    } <<<"$FORM_DATA"
    unset IFS

    [ -z "$FORM_ACTION" ] && return 0

    if [[ "$FORM_ACTION" = $(basename_url "$FORM_ACTION") ]]; then
        FORM_ACTION="$BASE_URL$FORM_ACTION"
    fi

    PAGE=$(curl -b "$COOKIE_FILE" \
        -H 'Expect: ' \
        -F "fn=$FILE_CODE" \
        -F "st=$STATE" \
        -F "op=$OP" \
        $FORM_LINK_RCPT \
        "$FORM_ACTION") || return

    echo "$PAGE"
}

# Handle state (upload)
# $1: upload state info
# $?: proper error or 0 for success
xfilesharing_ul_handle_state_generic() {
    local STATE=$1

    if [ "$STATE" = 'OK' ]; then
        log_debug 'Upload successfull.'
    elif [ "$STATE" = 'unallowed extension' ]; then
        log_error 'File extension is forbidden.'
        return $ERR_FATAL
    elif [ "$STATE" = 'file is too big' ]; then
        log_error 'Uploaded file is too big.'
        return $ERR_SIZE_LIMIT_EXCEEDED
    elif [ "$STATE" = 'not enough disk space on your account' ]; then
        log_error 'Account space exceeded.'
        return $ERR_SIZE_LIMIT_EXCEEDED
    else
        log_error "Unknown upload state: $STATE"
        return $ERR_FATAL
    fi

    return 0
}

# Parse delete code from final page (upload)
# $1: (X)HTML page data
# stdout: delete code
xfilesharing_ul_parse_del_code_generic() {
    local PAGE=$1

    local DEL_CODE

    DEL_CODE=$(echo "$PAGE" | parse_quiet 'killcode=' 'killcode=\([[:alnum:]]\+\)')

    # Another mod style
    if [ -z "$DEL_CODE" ]; then
        DEL_CODE=$(echo "$PAGE" | parse_quiet 'del-' '\(del-[[:alnum:]]\{10\}\)')
        [ -n "$DEL_CODE" ] && log_debug 'Alternative kill link.'
    fi

    echo "$DEL_CODE"
}

# Parse file ID from final page (upload)
# $1: (X)HTML page data
# stdout: file ID
xfilesharing_ul_parse_file_id_generic() {
    local PAGE=$1

    local FILE_ID

    FILE_ID=$(echo "$PAGE" | parse_quiet 'id="ic[0-9]-' 'id="ic[0-9]-\([0-9]\+\)')

    if [ -z "$FILE_ID" ]; then
        if match 'id="ic[0-9]-"' "$PAGE"; then
            log_debug 'File ID display most probably disabled.'
        else
            log_debug 'File ID is missing on upload result page.'
        fi
    fi

    echo "$FILE_ID"
}

# Move file into selected folder (upload)
# $1: cookie file
# $2: base URL
# $3: file ID to move
# $4: folder data
# $?: 0 for success
xfilesharing_ul_move_file_generic() {
    local COOKIE_FILE=$1
    local BASE_URL=$2
    local FILE_ID=$3
    local FOLDER_DATA=$4

    local PAGE LOCATION FOLDER_ID TOKEN TOKEN_OPT COMMAND

    { read FOLDER_ID; read TOKEN; read COMMAND; } <<<"$FOLDER_DATA"

    [ -n "$TOKEN" ] && TOKEN_OPT="-F token=$TOKEN"
    [ -z "$COMMAND" ] && COMMAND='to_folder_move=Move files'

    # Source folder ("fld_id") is always root ("0") for newly uploaded files
    PAGE=$(curl -b "$COOKIE_FILE" -i \
        -H 'Expect: ' \
        -F 'op=my_files' \
        -F 'fld_id=0' \
        -F "file_id=$FILE_ID" \
        -F "to_folder=$FOLDER_ID" \
        -F "$COMMAND" \
        $TOKEN_OPT \
        "$BASE_URL/") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)
    # fld_id0.php oteupload.com special
    if match '?op=my_files\|fld_id0' "$LOCATION"; then
        log_debug 'File moved.'
    else
        log_error 'Could not move file.'
    fi

    return 0
}

# Edit file (upload)
#  Sometimes required to edit file if some options could not be set while upload.
# $1: cookie file
# $2: base URL
# $3: file code
# $4: remote filename
# $?: 0 for success
xfilesharing_ul_edit_file_generic() {
    local COOKIE_FILE=$1
    local BASE_URL=$2
    local FILE_CODE=$3
    local DEST_FILE=$4

    local PAGE LOCATION PUBLIC_FLAG EDIT_FILE_NAME

    if [ -z "$PRIVATE_FILE" ]; then
        PUBLIC_FLAG=1
    else
        PUBLIC_FLAG=0
    fi

    if [ -z "$PREMIUM" ]; then
        PREMIUM_FLAG=0
    else
        PREMIUM_FLAG=1
    fi

    #if [ "$DEST_FILE" = 'dummy' ] || [ -n "$PREMIUM" ]; then
    log_debug 'Getting original filename & checking premium flag...'

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -H 'Expect: ' \
        -d 'op=file_edit' \
        -d "file_code=$FILE_CODE" \
        "$BASE_URL/" | break_html_lines) || return

    EDIT_FILE_NAME=$(echo "$PAGE" | parse_form_input_by_name_quiet 'file_name')

    if [ -n "$EDIT_FILE_NAME" ]; then
        if [ "$DEST_FILE" != 'dummy' ]; then
            EDIT_FILE_NAME="-F file_name=$DEST_FILE"
        else
            EDIT_FILE_NAME="-F file_name=$EDIT_FILE_NAME"
        fi
    elif [ "$DEST_FILE" != 'dummy' ]; then
        log_debug 'Cannot rename file on this hosting.'
    fi

    if match '<input[^>]*file_premium_only' "$PAGE"; then
        PREMIUM_OPT="-F file_premium_only=$PREMIUM_FLAG"
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -i \
        -H 'Expect: ' \
        -e "$BASE_URL/?op=file_edit&file_code=$FILE_CODE" \
        -F 'op=file_edit' \
        -F "file_code=$FILE_CODE" \
        $EDIT_FILE_NAME \
        -F "file_descr=$DESCRIPTION" \
        -F "file_password=$LINK_PASSWORD" \
        -F "file_public=$PUBLIC_FLAG" \
        $PREMIUM_OPT \
        -F "save=Submit" \
        "$BASE_URL/?op=file_edit&file_code=$FILE_CODE") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location_quiet)
    if match '?op=my_files' "$LOCATION" || match '?op=file_edit' "$LOCATION"; then
        log_debug 'File edited.'
    else
        log_error 'Cannot edit file.'
    fi

    return 0
}

# Set flag for premium-only download (upload)
# $1: cookie file
# $2: base URL
# $3: file ID
# $?: 0 for success
xfilesharing_ul_set_flag_premium_generic() {
    local COOKIE_FILE=$1
    local BASE_URL=$2
    local FILE_ID=$3

    local PAGE

    PAGE=$(curl -b "$COOKIE_FILE" -G \
    -H 'Expect: ' \
    -d 'op=my_files' \
    -d "file_id=$FILE_ID" \
    -d 'set_premium_only=true' \
    -d 'rnd='$(random js) \
    "$BASE_URL/") || return

    if match "\$\$('tpo$FILE_ID').className=" "$PAGE"; then
        log_debug 'Premium flag set.'
    else
        log_error 'Could not set premium only flag. Is it supported on site?'
    fi

    return 0
}

# Set public flag, controls visibility in public folder (upload)
# $1: cookie file
# $2: base URL
# $3: file ID
# $?: 0 for success
xfilesharing_ul_set_flag_public_generic() {
    local COOKIE_FILE=$1
    local BASE_URL=$2
    local FILE_ID=$3

    local PAGE PUBLIC_FLAG

    if [ -z "$PRIVATE_FILE" ]; then
        PUBLIC_FLAG='true'
    else
        PUBLIC_FLAG='false'
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -H 'Expect: ' \
        -d 'op=my_files' \
        -d "file_id=$FILE_ID" \
        -d "set_public=$PUBLIC_FLAG" \
        -d 'rnd='$(random js) \
        "$BASE_URL/") || return

    if match "\$\$('td$FILE_ID').className=" "$PAGE"; then
        log_debug 'Public flag set.'
    else
        log_error 'Could not set public flag. Is it supported on site?'
    fi

    return 0
}

# Generate final download and delete links (upload)
# $1: base URL
# $2: file code
# $3: (optional) delete code
# $4: (optional) file name
# stdout: file download URL
#         file delete URL
xfilesharing_ul_generate_links_generic() {
    local BASE_URL=$1
    local FILE_CODE=$2
    local DEL_CODE=$3
    local FILE_NAME=$4

    if match '^[A-Z0-9]\+$' "$FILE_CODE"; then
        echo "$BASE_URL/$FILE_CODE/$FILE_NAME.html"
        echo "$BASE_URL/del-$FILE_CODE-$DEL_CODE/$FILE_NAME.html"
    else
        echo "$BASE_URL/$FILE_CODE"
        if [ -n "$DEL_CODE" ] && match '^del-' "$DEL_CODE"; then
            echo "$BASE_URL/$FILE_CODE-$DEL_CODE/$FILE_NAME"
        elif [ -n "$DEL_CODE" ]; then
            echo "$BASE_URL/$FILE_CODE?killcode=$DEL_CODE"
        fi
    fi

    return 0
}

# Test for remote upload queue support (upload)
# $1: (X)HTML page data
# stdout: 1 if supported, 0 otherwise
xfilesharing_ul_remote_queue_test_generic() {
    local -r PAGE=$1

    if match '?op=upload_url' "$PAGE"; then
        echo "upload_url"
    elif match '?op=url_upload' "$PAGE"; then
        echo "url_upload"
    fi
}

# Add url to remote upload queue (upload)
# $1: cookie file
# $2: base URL
# $3: remote URL
# $4: remote upload op
xfilesharing_ul_remote_queue_add_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r FILE=$3
    local -r REMOTE_UPLOAD_QUEUE_OP=$4

    local PAGE

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' -L \
        -H 'Expect: ' \
        -F "op=$REMOTE_UPLOAD_QUEUE_OP" \
        -F "urls=$FILE" \
        -F 'cat_id=0' \
        -F 'tos=1' \
        -F 'submit_btn=Add to upload queue' \
        "$BASE_URL/") || return

    #MSG=$(parse_cookie_quiet 'msg' < "$COOKIE_FILE")

    if ! match '1 URLs were added to upload queue' "$PAGE"; then
        log_error 'Failed to add new URL into queue.'
        return $ERR_FATAL
    fi

    return 0
}

# Delete url from remote upload queue (upload)
#  removes last URL from upload queue, used for errors
# $1: cookie file
# $2: base URL
# $3: remote upload op
xfilesharing_ul_remote_queue_del_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r REMOTE_UPLOAD_QUEUE_OP=$3

    local PAGE DEL_ID LOCATION

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' -G \
        -d "op=$REMOTE_UPLOAD_QUEUE_OP" \
        "$BASE_URL/") || return

    DEL_ID=$(parse 'del_id=' 'del_id=\([0-9]\+\)' <<< "$PAGE") || return

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' -i -G \
        -d "op=$REMOTE_UPLOAD_QUEUE_OP" \
        -d "del_id=$DEL_ID" \
        "$BASE_URL/") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")
    if match "?op=$REMOTE_UPLOAD_QUEUE_OP" "$LOCATION"; then
        log_debug 'URL removed.'
    else
        log_error 'Cannot remove URL from queue.'
    fi

    return 0
}

# Check queue for active tasks (upload)
# $1: cookie file
# $2: base url
# $3: remote upload op
xfilesharing_ul_remote_queue_check_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r REMOTE_UPLOAD_QUEUE_OP=$3

    local PAGE

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' -G \
        -d "op=$REMOTE_UPLOAD_QUEUE_OP" \
        "$BASE_URL/") || return

    if match '<TD>PENDING</TD>\|<TD>WORKING</TD>' "$PAGE"; then
        log_debug "QUEUE: found working"
        return 1
    elif match 'Your Pending URL uploads' "$PAGE"; then
        log_debug "QUEUE: found error"
        parse_quiet '<TD>ERROR:' '<TD>ERROR:\([^<]\+\)' <<< "$PAGE"
        return 2
    else
        log_debug "QUEUE: found nothing"
        return 0
    fi
}

# Get last uploaded file code from user page (upload)
# $1: cookie file (logged into account)
# $2: base URL
# stdout: file code
xfilesharing_ul_get_file_code_generic() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local PAGE FILE_CODE

    log_debug 'Trying to get file code form user page...'

    PAGE=$(curl -b "$COOKIE_FILE" -G \
        -d 'op=my_files' \
        "$BASE_URL/") || return

    FILE_CODE=$(parse_quiet "<input[^>]*name=['\"]\?file_id['\"]\?" 'href="https\?://.*/\([[:alnum:]]\{12\}\)' 1 <<< "$PAGE")
    if [ -z "$FILE_CODE" ]; then
        log_error 'Cannot get file CODE from user page.'
        return $ERR_FATAL
    else
        echo "$FILE_CODE"
        return 0
    fi
}

# Parse file name (probe)
# $1: (X)HTML page data
# stdout: file name
xfilesharing_pr_parse_file_name_generic() {
    local -r PAGE=$1
    local FILE_NAME

    FILE_NAME=$(parse_quiet "\[[Uu][Rr][Ll]=.*\].* [-|] [0-9.]\+[[:space:]]*[KMGBb]\+\[/[Uu][Rr][Ll]\]" "\[[Uu][Rr][Ll]=.*\]\(.*\) [-|] [0-9.]\+[[:space:]]*[KMGBb]\+\[/[Uu][Rr][Ll]\]" <<< "$PAGE")
    [ -z "$FILE_NAME" ] && FILE_NAME=$(parse_quiet 'File[[:space:]]*[Nn]ame:' 'File[[:space:]]*[Nn]ame:.*>\([^<]\+\)<' <<< "$PAGE")
    [ -z "$FILE_NAME" ] && FILE_NAME=$(parse_quiet 'File[[:space:]]*[Nn]ame[[:space:]]*:[[:space:]]*' 'File[[:space:]]*[Nn]ame[[:space:]]*:[[:space:]]*\([[:alnum:]._]\+\)' <<< "$PAGE")

    if [ -z "$FILE_NAME" ]; then
        IMAGE_DATA=$(xfilesharing_dl_parse_imagehosting_generic "$PAGE")
        { read -r URL; read -r FILE_NAME; } <<<"$IMAGE_DATA"
    fi

    echo "$FILE_NAME"
}

# Parse file size (probe)
# $1: (X)HTML page data
# stdout: file size
xfilesharing_pr_parse_file_size_generic() {
    local -r PAGE=$1
    local -r FILE_NAME=$2
    local FILE_SIZE

    FILE_SIZE=$(parse_quiet '([[:space:]]*[0-9.]\+[[:space:]]*[KMGBb]\+[[:space:]]*)' '([[:space:]]*\([0-9.]\+[[:space:]]*[KMGBb]\+\?\)[[:space:]]*)' <<< "$PAGE")
    [ -z "$FILE_SIZE" ] && FILE_SIZE=$(parse_quiet '([[:space:]]*[0-9.]\+[[:space:]]*[KMGBb]\+[[:space:]]*)' '([[:space:]]*\([0-9.]\+[[:space:]]*[KMGBb]\+\?\)[[:space:]]*)' <<< "$PAGE")
    [ -z "$FILE_SIZE" ] && FILE_SIZE=$(parse_quiet '([^>]*>[[:space:]]*[0-9.]\+[[:space:]]*[KMGBb]\+[[:space:]]*<[^)]*)' '([^>]*>[[:space:]]*\([0-9.]\+[[:space:]]*[KMGBb]\+\?\)[[:space:]]*<[^)]*)' <<< "$PAGE")
    [ -z "$FILE_SIZE" ] && FILE_SIZE=$(parse_quiet "\[[Uu][Rr][Ll]=.*\].* [-|] [0-9.]\+[[:space:]]*[KMGBb]\+\[/[Uu][Rr][Ll]\]" "\[[Uu][Rr][Ll]=.*\].* [-|] \([0-9.]\+[[:space:]]*[KMGBb]\+\)\[/[Uu][Rr][Ll]\]" <<< "$PAGE")
    [ -z "$FILE_SIZE" ] && FILE_SIZE=$(parse_quiet 'Size:' '[[:space:]>]\([0-9.]\+[[:space:]]*[KMGBb]\+\)[[:space:]<]' <<< "$PAGE")

    [ -z "$FILE_SIZE" -a -n "$FILE_NAME" ] && FILE_SIZE=$(parse_quiet "$FILE_NAME" "$FILE_NAME.*[^[:alnum:]]\([0-9.]\+[[:space:]]*[KMGBb]\+\)[^[:alnum:]]" <<< "$PAGE")

    echo "$FILE_SIZE"
}

# Parse links (list)
# $1: (X)HTML page data
# stdout: links list
xfilesharing_ls_parse_links_generic() {
    local -r PAGE=$1
    local LINKS

    if match "<div class=[\"']\?link[\"']\?" "$PAGE"; then
        LINKS=$(parse_all_attr_quiet "<div class=[\"']\?link[\"']\?" 'href' <<< "$PAGE")
    elif match '<TD><b><a href="' "$PAGE"; then
        LINKS=$(parse_all_attr_quiet '<TD><b><a href="' 'href' <<< "$PAGE")
    fi

    echo "$LINKS"
}

# Parse file names (list)
# $1: (X)HTML page data
# stdout: names list
xfilesharing_ls_parse_names_generic() {
    local -r PAGE=$1
    local NAMES

    if match "<div class=[\"']\?link[\"']\?" "$PAGE"; then
        NAMES=$(parse_all_tag_quiet "<div class=[\"']\?link[\"']\?" 'a' <<< "$PAGE")
    elif match '<TD><b><a href="' "$PAGE"; then
        NAMES=$(parse_all_tag_quiet '<TD><b><a href="' 'a' <<< "$PAGE")
    fi

    echo "$NAMES"
}

# Parse last page number (list)
#  for big folders
# $1: (X)HTML page data
# stdout: last page number
xfilesharing_ls_parse_last_page_generic() {
    local -r PAGE=$1
    local LAST_PAGE

    LAST_PAGE=$(echo "$PAGE" | parse_tag_quiet 'class="paging"' 'div' | break_html_lines | \
        parse_all_quiet . 'page=\([0-9]\+\)')

    if [ -n "$LAST_PAGE" ];then
        # The last button is 'Next', last page button right before
        LAST_PAGE=$(echo "$LAST_PAGE" | delete_last_line | last_line)
    fi

    echo "$LAST_PAGE"
}

# Parse folder names (list)
# $1: (X)HTML page data
# stdout: folders list
xfilesharing_ls_parse_folders_generic() {
    local -r PAGE=$1
    local FOLDERS FOLDER

    FOLDERS=$(parse_all_attr_quiet 'folder2.gif' 'href' <<< "$PAGE") || return

    if [ -n "$FOLDERS" ]; then
        # First folder can be parent folder (". .") - drop it to avoid infinite loops
        FOLDER=$(parse_tag_quiet 'folder2.gif' 'b' <<< "$PAGE") || return
        [ "$FOLDER" = '. .' ] && FOLDERS=$(delete_first_line <<< "$FOLDERS")
    fi

    echo "$FOLDERS"
}
