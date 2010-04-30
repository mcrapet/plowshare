#!/bin/bash
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

MODULE_RAPIDSHARE_REGEXP_URL="http://\(www\.\)\?rapidshare\.com/"
MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use Premium-Zone account"
MODULE_RAPIDSHARE_UPLOAD_OPTIONS="
AUTH_PREMIUMZONE,a:,auth:,USER:PASSWORD,Use Premium-Zone account
AUTH_FREEZONE,b:,auth-freezone:,USER:PASSWORD,Use Free-Zone account"
MODULE_RAPIDSHARE_DELETE_OPTIONS=
MODULE_RAPIDSHARE_DOWNLOAD_CONTINUE=no

# Output a rapidshare file download URL (anonymous and premium)
#
# rapidshare_download RAPIDSHARE_URL
#
# Note to premium users: In your account settings, uncheck option:
# "Direct downloads, requested files are saved without redirection via RapidShare"
# The trick to direct download (not used here) is to append "directstart=1" to URL.
# For example: http://rapidshare.com/files/12345678/foo_bar_file_name?directstart=1
rapidshare_download() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    COOKIES=$(create_tempfile)

    # Try to login if account provided
    # Even if login/passwd are wrong cookie content is returned
    if [ -n "$AUTH" ]; then
        LOGIN_DATA='uselandingpage=1&submit=Premium%20Zone%20Login&login=$USER&password=$PASSWORD'
        post_login "$AUTH" "$COOKIES" "$LOGIN_DATA" \
                "https://ssl.rapidshare.com/cgi-bin/premiumzone.cgi" >/dev/null || {
            rm -f $COOKIES
            return 1
        }
    fi

    while retry_limit_not_reached || return 3; do
        if [ -z "$AUTH" ]; then
            PAGE=$(curl "$URL")
        else
            PAGE=$(curl -b $COOKIES "$URL")
        fi

        # Detect "Direct downloads" (premium user) option
        if [ -n "$AUTH" -a -z "$PAGE" -a ! "$CHECK_LINK" ]; then
            FILE_URL=$(curl -b $COOKIES -i "$URL" | grep_http_header_location)
            echo $FILE_URL
            echo
            echo $COOKIES
            return 0
        fi

        # Check for errors:
        # - The file could not be found. Please check the download link.
        # - This file has been removed from the server, because the file has not been accessed in a long time.
        # - This file is neither allocated to a Premium Account, or a Collector's Account, and can therefore only be downloaded 10 times.
        # - Due to a violation of our terms of use, the file has been removed from the server.
        if match "<h1>Error</h1>" "$PAGE"; then
            match 'file could not be found' "$PAGE" &&
                log_debug "file not found"
            match 'suspected to contain illegal content' "$PAGE" &&
                log_debug "file blocked"
            match 'uploader has removed this file from the server' "$PAGE" &&
                log_debug "file removed by the uploader"
            match 'removed from the server, because the file has not been accessed' "$PAGE" &&
                log_debug "file removed"
            match 'This limit is reached.' "$PAGE" &&
                log_debug "file blocked"
            match 'violation of our terms' "$PAGE" &&
                log_debug "file removed"

            rm -f $COOKIES
            return 254
        fi

        if test "$CHECK_LINK"; then
            rm -f $COOKIES
            return 255
        fi

        WAIT_URL=$(grep_form_by_id "$PAGE" 'ff' | parse_form_action) ||
            return 1

        if [ -z "$AUTH" ]; then
            DATA=$(curl --data "dl.start=Free" "$WAIT_URL")
        else
            DATA=$(curl -b $COOKIES --data "dl.start=PREMIUM" "$WAIT_URL")
            match 'Your Cookie has not been recognized' "$DATA" &&
                { log_error "login process failed"; return 1; }
        fi

        test -z "$DATA" &&
            { log_error "can't get wait URL contents"; return 1; }

        match "is already downloading a file" "$DATA" && {
            log_debug "Your IP is already downloading a file"
            wait 2 minutes || return 2
            continue
        }

        LIMIT=$(echo "$DATA" | parse "minute" \
                "[[:space:]]\([[:digit:]]\+\) minutes[[:space:]]" 2>/dev/null) && {
            log_debug "No free slots, server asked to wait $LIMIT minutes"
            wait $LIMIT minutes || return 2
            continue
        }

        FILE_URL=$(grep_form_by_name "$DATA" 'dlf' | parse_form_action 2>/dev/null) || {
            log_debug "No free slots, waiting 2 minutes (default value)"
            wait 2 minutes || return 2
            continue
        }

        break
    done

    if [ -z "$AUTH" ]; then
        SLEEP=$(echo "$DATA" | parse "^var c=" "c=\([[:digit:]]\+\);") || return 1
        wait $((SLEEP + 1)) seconds || return 2
        rm -f $COOKIES
        echo $FILE_URL
    else
        echo $FILE_URL
        echo
        echo $COOKIES
    fi

    return 0
}

# Upload a file to Rapidshare (anonymously, Free-Zone or Premium-Zone)
#
# rapidshare_upload [OPTIONS] FILE [DESTFILE]
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#   -b USER:PASSWORD, --auth-freezone=USER:PASSWORD
#
rapidshare_upload() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"

    if test -n "$AUTH_PREMIUMZONE"; then
        rapidshare_upload_premiumzone "$@"
    elif test -n "$AUTH_FREEZONE"; then
        rapidshare_upload_freezone "$@"
    else
        rapidshare_upload_anonymous "$@"
    fi
}

# Upload a file to Rapidshare (anonymously) and return LINK_URL (KILL_URL)
#
# rapidshare_upload_anonymous FILE [DESTFILE]
#
rapidshare_upload_anonymous() {
    set -e
    FILE=$1
    DESTFILE=${2:-$FILE}

    UPLOAD_URL="http://www.rapidshare.com"
    log_debug "downloading upload page: $UPLOAD_URL"

    local DATA=$(curl "$UPLOAD_URL")
    ACTION=$(grep_form_by_name "$DATA" 'ul' | parse_form_action) || return 1
    log_debug "upload to: $ACTION"

    INFO=$(curl -F "filecontent=@$FILE;filename=$(basename "$DESTFILE")" "$ACTION") || return 1
    URL=$(echo "$INFO" | parse "downloadlink" ">\(.*\)<") || return 1
    KILL=$(echo "$INFO" | parse "loeschlink" ">\(.*\)<")

    echo "$URL ($KILL)"
}

# Upload a file to Rapidshare (Free-Zone) and return LINK_URL
#
# rapidshare_upload_freezone [OPTIONS] FILE [DESTFILE]
#
# Options:
#   -b USER:PASSWORD, --auth-freezone=USER:PASSWORD
#
rapidshare_upload_freezone() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"
    local FILE=$1
    local DESTFILE=${2:-$FILE}

    COOKIES=$(create_tempfile)
    FREEZONE_LOGIN_URL="https://ssl.rapidshare.com/cgi-bin/collectorszone.cgi"

    LOGIN_DATA='username=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH_FREEZONE" "$COOKIES" "$LOGIN_DATA" "$FREEZONE_LOGIN_URL") || {
        rm -f $COOKIES
        return 1
    }

    if match 'The Account has been found, password incorrect' "$LOGIN_RESULT"; then
        log_error "login process failed (wrong password)"
        rm -f $COOKIES
        return 1
    fi

    log_debug "downloading upload page: $FREEZONE_LOGIN_URL"
    UPLOAD_PAGE=$(curl -b $COOKIES $FREEZONE_LOGIN_URL) || return 1

    ACCOUNTID=$(echo "$UPLOAD_PAGE" | \
        parse 'name="freeaccountid"' 'value="\([[:digit:]]*\)"')
    ACTION=$(echo "$UPLOAD_PAGE" | parse '<form name="ul"' 'action="\([^"]*\)"')
    IFS=":" read USER PASSWORD <<< "$AUTH_FREEZONE"
    log_debug "uploading file: $FILE"
    UPLOADED_PAGE=$(curl -b $COOKIES \
        -F "filecontent=@$FILE;filename=$(basename "$DESTFILE")" \
        -F "freeaccountid=$ACCOUNTID" \
        -F "password=$PASSWORD" \
        -F "mirror=on" $ACTION) || return 1

    log_debug "download upload page to get url: $FREEZONE_LOGIN_URL"
    UPLOAD_PAGE=$(curl -b $COOKIES $FREEZONE_LOGIN_URL) || return 1

    rm -f $COOKIES

    FILEID=$(echo "$UPLOAD_PAGE" | grep ^Adliste | tail -n1 | \
        parse Adliste 'Adliste\["\([[:digit:]]*\)"')
    MATCH="^Adliste\[\"$FILEID\"\]"
    KILLCODE=$(echo "$UPLOAD_PAGE" | parse "$MATCH" "killcode\"\] = '\(.*\)'") || return 1
    FILENAME=$(echo "$UPLOAD_PAGE" | parse "$MATCH" "filename\"\] = \"\(.*\)\"") || return 1

    # There is a killcode in the HTML, but it's not used to build a URL
    # but as a param in a POST submit, so I assume there is no kill URL for
    # freezone files. Therefore, output just the file URL.
    URL="http://rapidshare.com/files/$FILEID/$FILENAME.html"
    echo "$URL"
}

# Upload a file to Rapidshare (Premium-Zone) and return LINK_URL
#
# rapidshare_upload_premiumzone [OPTIONS] FILE [DESTFILE]
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#
rapidshare_upload_premiumzone() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"
    local FILE=$1
    local DESTFILE=${2:-$FILE}

    COOKIES=$(create_tempfile)
    PREMIUMZONE_LOGIN_URL="https://ssl.rapidshare.com/cgi-bin/premiumzone.cgi"

    # Even if login/passwd are wrong cookie content is returned
    LOGIN_DATA='uselandingpage=1&submit=Premium%20Zone%20Login&login=$USER&password=$PASSWORD'
    post_login "$AUTH_PREMIUMZONE" "$COOKIES" "$LOGIN_DATA" "$PREMIUMZONE_LOGIN_URL" >/dev/null || {
        rm -f $COOKIES
        return 1
    }

    log_debug "downloading upload page: $PREMIUMZONE_LOGIN_URL"
    UPLOAD_PAGE=$(curl -b $COOKIES $PREMIUMZONE_LOGIN_URL) || return 1

    if test -z "$UPLOAD_PAGE"; then
        log_error "login process failed"
        rm -f $COOKIES
        return 1
    fi

    # Extract upload form part
    UPLOAD_PAGE=$(grep_form_by_name "$UPLOAD_PAGE" 'ul')

    local form_url=$(echo "$UPLOAD_PAGE" | parse_form_action)
    local form_login=$(echo "$UPLOAD_PAGE" | parse_form_input_by_name "login")
    local form_password=$(echo "$UPLOAD_PAGE" | parse_form_input_by_name "password")

    log_debug "uploading file: $FILE"
    UPLOADED_PAGE=$(curl -b $COOKIES \
        -F "login=$form_login" \
        -F "password=$form_password" \
        -F "filecontent=@$FILE;filename=$(basename "$DESTFILE")" \
        -F "mirror=on" \
        -F "u.x=56" -F "u.y=9" "$form_url") || return 1

    log_debug "download upload page to get url: $PREMIUMZONE_LOGIN_URL"
    UPLOAD_PAGE=$(curl -b $COOKIES $PREMIUMZONE_LOGIN_URL) || return 1

    rm -f $COOKIES

    FILEID=$(echo "$UPLOAD_PAGE" | grep ^Adliste | head -n1 | \
        parse Adliste 'Adliste\["\([[:digit:]]*\)"')
    MATCH="^Adliste\[\"$FILEID\"\]"
    KILLCODE=$(echo "$UPLOAD_PAGE" | parse "$MATCH" 'killcode"\] = "\([^"]*\)') || return 1
    FILENAME=$(echo "$UPLOAD_PAGE" | parse "$MATCH" 'filename"\] = "\([^"]*\)') || return 1

    URL="http://rapidshare.com/files/$FILEID/$FILENAME.html"
    echo "$URL"
}

# Delete a file from rapidshare
#
# rapidshare_delete [MODULE_RAPIDSHARE_DELETE_OPTIONS] URL
#
rapidshare_delete() {
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_DELETE_OPTIONS" "$@")"
    URL=$1

    KILL_URL=$(curl "$URL" | parse 'value="Delete this file now"' "href='\([^\"']*\)" 2>/dev/null) ||
        { log_error "bad kill link"; return 1; }

    log_debug "kill_url=$KILL_URL"
    local RESULT=$(curl "$KILL_URL")

    if ! match 'The following file has been deleted' "$RESULT"; then
        log_debug "unexpected result"
    fi
}
