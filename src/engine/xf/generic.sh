#!/bin/bash
#
# xfilesharing callbacks
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
    [parse_error]=xf_parse_error_generic
    [parse_form1]=xf_parse_form1_generic
    [parse_form2]=xf_parse_form2_generic
    [parse_final_link]=xf_parse_final_link_generic
    [commit_step1]=xf_commit_step1_generic
    [commit_step2]=xf_commit_step2_generic)'

xf_parse_error_generic() {
    local PAGE=$1
    local CAPTCHA_ID=$2
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
    elif match 'You have to wait\|You can download files up to\|Video [Ii][sn] [Ee]ncoding\|Wrong password\|Wrong captcha\|Skipped countdown' "$PAGE"; then
        ERROR="$PAGE"
        ERROR_NOBLOCK=1
    fi

    [ -z "$ERROR" ] && return 0

    # You have reached the download-limit for free-users.<br>Get your own Premium-account now!<br>(Or wait 3 seconds)
    # www.caiuaqui.com
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
        #echo $(( HOURS * 60 * 60 + MINS * 60 + SECS ))
        #return $ERR_LINK_TEMP_UNAVAILABLE
        return $ERR_FATAL
    elif match 'You can download files up to .* only' "$PAGE"; then
        return $ERR_SIZE_LIMIT_EXCEEDED

    elif match 'Video [Ii][sn] [Ee]ncoding' "$ERROR"; then
        log_error 'Video is encoding now. Try again later.'
        return $ERR_LINK_TEMP_UNAVAILABLE

    # Check this only if proper error block parsed
    elif [ $ERROR_NOBLOCK -eq 0 ] && match 'premium' "$ERROR"; then
        return $ERR_LINK_NEED_PERMISSIONS

    # Stage 2 errors
    elif match 'Wrong password' "$ERROR"; then
        return $ERR_LINK_PASSWORD_REQUIRED

    elif match 'Wrong captcha' "$ERROR"; then
        log_error 'Wrong captcha'
        [ -n "$CAPTCHA_ID" ] && captcha_nack $CAPTCHA_ID
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

xf_parse_form1_generic() {
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
        # freemethod for cramit.in
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

    echo "$FORM_HTML"
}

xf_parse_form2_generic() {
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
    echo "$FORM_ADD"

    echo "$FORM_HTML"
}

xf_parse_final_link_generic() {
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

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

xf_commit_step1_generic() {
    local PAGE=$1
    local -r COOKIE_FILE=$2
    local -r FORM_ACTION=$3
    local -r FORM_DATA=$4

    local FORM_HTML FORM_OP FORM_ID FORM_USR FORM_FNAME FORM_REFERER FORM_HASH FORM_METHOD_F FORM_ADD
    local OLDIFS

    OLDIFS=$IFS
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
    read -r -d '' FORM_HTML;
    } <<<"$FORM_DATA"
    IFS=$OLDIFS

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

xf_commit_step2_generic() {
    local PAGE=$1
    local -r COOKIE_FILE=$2
    local -r FORM_ACTION=$3
    local -r FORM_DATA=$4
    local -r FORM_PASSWORD=$5
    local -r FORM_CAPTCHA=$6

    local FORM_FNAME FORM_OP FORM_ID FORM_RAND FORM_REFERER FORM_METHOD_F FORM_METHOD_P FORM_DD
    local EXTRA OLDIFS

    OLDIFS=$IFS
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
    read -r FORM_ADD;
    read -r -d '' FORM_HTML;
    } <<<"$FORM_DATA"
    IFS=$OLDIFS

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
