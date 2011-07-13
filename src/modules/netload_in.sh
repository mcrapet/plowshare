#!/bin/bash
#
# netload.in module
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

MODULE_NETLOAD_IN_REGEXP_URL="http://\(www\.\)\?net\(load\|folder\)\.in/"

MODULE_NETLOAD_IN_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Premium account"
MODULE_NETLOAD_IN_DOWNLOAD_RESUME=no
MODULE_NETLOAD_IN_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_NETLOAD_IN_LIST_OPTIONS=""

# Output an netload.in file download URL (anonymous)
# $1: cookie file
# $2: netload.in url
# stdout: real file download link
netload_in_download() {
    eval "$(process_options rapidshare "$MODULE_NETLOAD_IN_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL=$(echo "$2" | replace 'www.' '')
    local BASE_URL="http://netload.in"

    if [ -n "$AUTH" ]; then
        netload_in_premium_login "$AUTH" "$COOKIEFILE" "$BASE_URL" || return 1
        MODULE_NETLOAD_IN_DOWNLOAD_RESUME=yes

        PAGE=$(curl -i -b "$COOKIEFILE" "$URL")
        FILE_URL=$(echo "$PAGE" | grep_http_header_location)

        # Account download method set to "Automatisch"
        # HTTP HEAD request discarded, can't read "Content-Disposition" header
        if [ -n "$FILE_URL" ]; then

            # Only solution to get filename
            PAGE=$(curl -L "$URL")

            echo "$FILE_URL"
            echo "$PAGE" | parse_line_after 'dl_first_filename' '			\([^<]*\)'
            return 0
        fi

        echo "$PAGE" | parse_attr 'Orange_Link' 'href'
        echo "$PAGE" | parse '<h2>download:' ': \([^<]*\)'
        return 0
    fi

    local TRY=0
    while retry_limit_not_reached || return; do
        ((TRY++))
        WAIT_URL=$(curl --location -c $COOKIEFILE "$URL" | \
            parse_quiet '<div class="Free_dl">' '><a href="\([^"]*\)') ||
            { log_debug "file not found"; return $ERR_LINK_DEAD; }

        test "$CHECK_LINK" && return 0

        PERL_PRG=$(detect_perl) || return

        WAIT_URL="$BASE_URL/${WAIT_URL//&amp;/&}"
        WAIT_HTML=$(curl -b $COOKIEFILE -e $URL --location $WAIT_URL)
        WAIT_TIME=$(echo "$WAIT_HTML" | parse_quiet 'type="text\/javascript">countdown' \
                "countdown(\([[:digit:]]*\),'change()')")

        if test -n "$WAIT_TIME"; then
            wait $((WAIT_TIME / 100)) seconds || return
        fi

        CAPTCHA_URL=$(echo "$WAIT_HTML" | parse '<img style="vertical-align' \
                'src="\([^"]*\)" alt="Sicherheitsbild"')
        CAPTCHA_URL="$BASE_URL/$CAPTCHA_URL"

        log_debug "Try $TRY:"

        CAPTCHA=$(curl -b $COOKIEFILE "$CAPTCHA_URL" | $PERL_PRG $LIBDIR/strip_single_color.pl |
                convert - -quantize gray -colors 32 -blur 40% -contrast-stretch 6% -compress none -depth 8 tif:- |
                show_image_and_tee | ocr digit | sed "s/[^0-9]//g") ||
                { log_error "error running OCR"; return 1; }

        test "${#CAPTCHA}" -gt 4 && CAPTCHA="${CAPTCHA:0:4}"
        log_debug "Decoded captcha: $CAPTCHA"

        if [ "${#CAPTCHA}" -ne 4 ]; then
            log_debug "Captcha length invalid"
            continue
        fi

        # Send (post) form
        local download_form=$(grep_form_by_order "$WAIT_HTML" 1)
        local form_url=$(echo "$download_form" | parse_form_action)
        local form_fid=$(echo "$download_form" | parse_form_input_by_name 'file_id')

        WAIT_HTML2=$(curl -l -b $COOKIEFILE --data "file_id=${form_fid}&captcha_check=${CAPTCHA}&start=" \
                "$BASE_URL/$form_url")

        match 'class="InPage_Error"' "$WAIT_HTML2" &&
            { log_debug "Error (bad captcha), retry"; continue; }

        log_debug "Correct captcha!"

        WAIT_TIME2=$(echo "$WAIT_HTML2" | parse_quiet 'type="text\/javascript">countdown' \
                "countdown(\([[:digit:]]*\),'change()')")

        if [ -n "$WAIT_TIME2" ]
        then
            if [[ "$WAIT_TIME2" -gt 10000 ]]
            then
                log_debug "Download limit reached!"
                wait $((WAIT_TIME2 / 100)) seconds || return
            else
                # Supress this wait will lead to a 400 http error (bad request)
                wait $((WAIT_TIME2 / 100)) seconds || return
                break
            fi
        fi

    done

    FILENAME=$(echo "$WAIT_HTML2" |\
        parse_quiet '<h2>[Dd]ownload:' '<h2>[Dd]ownload:[[:space:]]*\([^<]*\)')
    FILE_URL=$(echo "$WAIT_HTML2" |\
        parse '<a class="Orange_Link"' 'Link" href="\(http[^"]*\)')

    echo $FILE_URL
    test -n "$FILENAME" && echo "$FILENAME"
    return 0
}

# $1: $AUTH argument string
# $2: cookie file
# $3: netload.in baseurl
netload_in_premium_login() {
    # Even if login/passwd are wrong cookie content is returned
    LOGIN_DATA='txtuser=$USER&txtpass=$PASSWORD&txtcheck=login&txtlogin='
    LOGIN_RESULT=$(post_login "$1" "$2" "$LOGIN_DATA" "$3/index.php" '-L') || return

    if match 'InPage_Error\|lostpassword\.tpl' "$LOGIN_RESULT"; then
        log_debug "login failed"
        return $ERR_LOGIN_FAILED
    fi
}

# List multiple netload.in links
# $1: netfolder.in link
# stdout: list of links
netload_in_list() {
    local URL="$1"

    if ! match 'folder' "$URL"; then
        log_error "This is not a directory list"
        return 1
    fi

    LINKS=$(curl "$URL" | break_html_lines_alt | parse_all_attr 'Link_[[:digit:]]' 'href') || \
        { log_error "Wrong directory list link"; return 1; }

    if test -z "$LINKS"; then
        log_error "This is not a directory list"
        return 1
    fi

    echo "$LINKS"
    return 0
}
