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

MODULE_MEDIAFIRE_REGEXP_URL="http://\(www\.\)\?mediafire.com/"
MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS=""
MODULE_MEDIAFIRE_UPLOAD_OPTIONS=
MODULE_MEDIAFIRE_DOWNLOAD_CONTINUE=no

# Output a mediafire file download URL
#
# meadifire_download URL
#
mediafire_download() {
    set -e
    eval "$(process_options mediafire "$MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    BASE_URL="http://www.mediafire.com"
    COOKIESFILE=$(create_tempfile)

    PAGE=$(curl -c $COOKIESFILE "$URL" | sed "s/>/>\n/g")
    COOKIES=$(< $COOKIESFILE)
    rm -f $COOKIESFILE
    
    echo "$PAGE" | grep -qi "Invalid or Deleted File" && 
        { error "file not found"; return 255; }
        
    JS_CALL=$(echo "$PAGE" | parse "cu('" "cu(\('[^)]*\));" 2>/dev/null) ||
        { error "error parsing Javascript code"; return 1; }
    test "$CHECK_LINK" && return 255
    
    IFS="," read QK PK R < <(echo "$JS_CALL" | tr -d "'")
    JS_URL="$BASE_URL/dynamic/download.php?qk=$QK&pk=$PK&r=$R"
    debug "Javascript URL: $JS_URL"

    JS_CODE=$(curl -b <(echo $COOKIES) "$JS_URL" | sed "s/;/;\n/g")

    # The File URL is ofuscated using a somewhat childish javascript code,
    # we use the default javascript interpreter (js) to run it.
    debug "running Javascript code"
    VARS=$(echo "$JS_CODE" | grep "^[[:space:]]*var")
    HREF=$(echo "$JS_CODE" | \
        parse "href=" "href=\\\\\(\"http.*\)+[[:space:]]*'\">")
    FILE_URL=$(echo "$VARS; print($HREF);" | js)
    echo "$FILE_URL"
}
