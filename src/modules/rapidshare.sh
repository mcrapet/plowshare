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
#
MODULE_RAPIDSHARE_REGEXP_URL="http://\(\w\+\.\)\?rapidshare.com/"
MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS=""
MODULE_RAPIDSHARE_UPLOAD_OPTIONS="
AUTH_FREEZONE,a:,auth-freezone:,USER:PASSWORD,Use a freezone account"
MODULE_RAPIDSHARE_DOWNLOAD_CONTINUE=no

# Output a rapidshare file download URL (anonymous, NOT PREMIUM)
#
# rapidshare_download RAPIDSHARE_URL
#
rapidshare_download() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    while true; do
        WAIT_URL=$(curl --silent "$URL" | parse '<form' 'action="\([^"]*\)"' 2>/dev/null) ||
            { error "file not found"; return 254; }
        test "$CHECK_LINK" && return 255
        DATA=$(curl --data "dl.start=Free" "$WAIT_URL") ||
            { error "can't get wait URL contents"; return 1; }
        ERR1="No more download slots available for free users right now"
        ERR2="Your IP address.*file"
        if echo "$DATA" | grep -o "$ERR1\|$ERR2" >&2; then
            WAITTIME=1
            debug "Sleeping $WAITTIME minute(s) before trying again"
            countdown $WAITTIME 1 minutes 60
            continue
        fi

        LIMIT=$(echo "$DATA" | parse "minute" "[[:space:]]\([[:digit:]]\+\) minute" 2>/dev/null || true)
        test -z "$LIMIT" && break
        debug "Download limit reached!"
        countdown $LIMIT 1 minutes 60
    done

    FILE_URL=$(echo "$DATA" | parse "<form " 'action="\([^"]*\)"')
    SLEEP=$(echo "$DATA" | parse "^var c=" "c=\([[:digit:]]\+\);")
    debug "URL File: $FILE_URL"
    countdown $((SLEEP + 1)) 30 seconds 1

    echo $FILE_URL
}

# Upload a file to Rapidshare (anonymously or free zone, NOT PREMIUM)
#
# rapidshare_upload [OPTIONS] FILE [DESTFILE]
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#
rapidshare_upload() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"
    if test "$AUTH_FREEZONE"; then
        rapidshare_upload_freezone "$@"
    else
        rapidshare_upload_anonymous "$@"
    fi
}

# Upload a file to Rapidshare anonymously and return link and kill URLs
#
# rapidshare_upload_anonymous FILE [DESTFILE]
#
rapidshare_upload_anonymous() {
    set -e
    FILE=$1
    DESTFILE=${2:-$FILE}
    UPLOAD_URL="http://www.rapidshare.com"
    debug "downloading upload page: $UPLOAD_URL"
    ACTION=$(curl "$UPLOAD_URL" | parse 'form name="ul"' 'action="\([^"]*\)')
    debug "upload to: $ACTION"
    INFO=$(curl -F "filecontent=@$FILE;filename=$(basename "$DESTFILE")" "$ACTION")
    URL=$(echo "$INFO" | parse "downloadlink" ">\(.*\)<")
    KILL=$(echo "$INFO" | parse "loeschlink" ">\(.*\)<")
    echo "$URL ($KILL)"
}

# Upload a file to Rapidshare (free zone)
#
# rapidshare_upload_freezone [OPTIONS] FILE [DESTFILE]
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#
rapidshare_upload_freezone() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"
    FILE=$1
    DESTFILE=${2:-$FILE}

    FREEZONE_LOGIN_URL="https://ssl.rapidshare.com/cgi-bin/collectorszone.cgi"
    LOGIN_DATA='username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH_FREEZONE" "$LOGIN_DATA" "$FREEZONE_LOGIN_URL") ||
        { error "error on login process"; return 1; }
    ccurl() { curl -b <(echo "$COOKIES") "$@"; }
    debug "downloading upload page: $UPLOAD_URL"
    UPLOAD_PAGE=$(ccurl $FREEZONE_LOGIN_URL)
    ACCOUNTID=$(echo "$UPLOAD_PAGE" | \
        parse 'name="freeaccountid"' 'value="\([[:digit:]]*\)"')
    ACTION=$(echo "$UPLOAD_PAGE" | parse '<form name="ul"' 'action="\([^"]*\)"')
    IFS=":" read USER PASSWORD <<< "$AUTH_FREEZONE"
    debug "uploading file: $FILE"
    UPLOADED_PAGE=$(ccurl \
        -F "filecontent=@$FILE;filename=$(basename "$DESTFILE")" \
        -F "freeaccountid=$ACCOUNTID" \
        -F "password=$PASSWORD" \
        -F "mirror=on" $ACTION)
    debug "download upload page to get url: $FREEZONE_LOGIN_URL"
    UPLOAD_PAGE=$(ccurl $FREEZONE_LOGIN_URL)
    FILEID=$(echo "$UPLOAD_PAGE" | grep ^Adliste | tail -n1 | \
        parse Adliste 'Adliste\["\([[:digit:]]*\)"')
    MATCH="^Adliste\[\"$FILEID\"\]"
    KILLCODE=$(echo "$UPLOAD_PAGE" | parse "$MATCH" "killcode\"\] = '\(.*\)'")
    FILENAME=$(echo "$UPLOAD_PAGE" | parse "$MATCH" "filename\"\] = \"\(.*\)\"")
    # There is a killcode in the HTML, but it's not used to build a URL
    # but as a param in a POST submit, so I assume there is no kill URL for
    # freezone files. Therefore, output just the file URL.
    URL="http://rapidshare.com/files/$FILEID/$FILENAME.html"
    echo "$URL"
}
