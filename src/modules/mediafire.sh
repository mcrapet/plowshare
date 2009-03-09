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
MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS=
MODULE_MEDIAFIRE_UPLOAD_OPTIONS=
MODULE_MEDIAFIRE_DOWNLOAD_CONTINUE=yes

# Output a mediafire file download URL
#
# meadifire_download URL
#
mediafire_download() {
    set -e
    eval "$(process_options mediafire "$MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS" "$@")"
    URL=$1
    
    BASE_URL="http://www.mediafire.com"
    COOKIES=$(create_tempfile)
    MAIN_PAGE=$(curl -c $COOKIES "$URL" | sed "s/>/>\n/g")
    JS_CALL=$(echo "$MAIN_PAGE" | parse "cu('" "cu('\([^)]*\));" | tr -d "'")
    IFS="," read QK PK R <<< "$JS_CALL"
    JS_URL="$BASE_URL/dynamic/download.php?qk=$QK&pk=$PK&r=$R"
    debug "Javascript URL: $JS_URL"
    JS_CODE=$(curl -b $COOKIES "$JS_URL" | sed "s/;/;\n/g")
    rm -f $COOKIES
    # The File URL is ofuscated using a somewhat childish javascript code, 
    # we use the default javascript interpreter (js) to run it. 
    debug "running Javascript code"
    VARS=$(echo "$JS_CODE" | grep "^[[:space:]]*var")
    HREF=$(echo "$JS_CODE" | parse "href=" "href=\\\\\(\"http.*\)+'\">")
    FILE_URL=$(echo "$VARS; print($HREF);" | js)
    echo "$FILE_URL"
}
