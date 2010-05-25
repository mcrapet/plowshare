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

MODULE_MEDIAFIRE_REGEXP_URL="http://\(www\.\)\?mediafire\.com/"
MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS=""
MODULE_MEDIAFIRE_UPLOAD_OPTIONS=
MODULE_MEDIAFIRE_LIST_OPTIONS=
MODULE_MEDIAFIRE_DOWNLOAD_CONTINUE=no

# Output a mediafire file download URL
# $1: MEDIAFIRE_URL
# stdout: real file download link
mediafire_download() {
    set -e
    eval "$(process_options mediafire "$MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    LOCATION=$(curl --head "$URL" | grep_http_header_location)
    if match '^http://download' "$LOCATION"; then
        log_notice "direct download"
        echo "$LOCATION"
        return 0
    elif match 'errno=999$' "$LOCATION"; then
        log_error "private link"
        return 254
    elif match 'errno=' "$LOCATION"; then
        log_error "site redirected with an unknown error"
        return 1
    fi

    COOKIESFILE=$(create_tempfile)
    PAGE=$(curl -L -c $COOKIESFILE "$URL" | sed "s/>/>\n/g")
    COOKIES=$(< $COOKIESFILE)
    rm -f $COOKIESFILE

    test "$PAGE" || return 254

    if matchi 'Invalid or Deleted File' "$PAGE"; then
        log_debug "invalid or deleted file"
        return 254
    fi

    if test "$CHECK_LINK"; then
        match 'class="download_file_title"' "$PAGE" && return 255 || return 1
    fi

    FILE_URL=$(get_ofuscated_link "$PAGE" "$COOKIES") ||
        { log_error "error running Javascript code"; return 1; }

    echo "$FILE_URL"
}

get_ofuscated_link() {
    local PAGE=$1
    local COOKIES=$2
    BASE_URL="http://www.mediafire.com"

    detect_javascript >/dev/null || return 1
    # Carriage-return in eval is not accepted by Spidermonkey, that's what the sed removes
    PAGE_JS=$(echo "$PAGE" | sed -n '/<input id="pagename"/,/<\/script>/p' |
              tail -n+3 | sed "s/<!--//; s/-->//" | head -n-1 |
              sed "N;N;N; s/var cb=Math.random().*$/}/") ||
        { log_error "cannot find javascript code"; return 1; }

    { read DIVID; read DYNAMIC_PATH; } < <(echo "
        noop = function () { }
        // These functions and variables are defined elsewhere, fake them.
        DoShow = Eo = aa = noop;
        fu = StartDownloadTried = 0;

        // Record accesses to the DOM
        namespace = {};
        var document = {
            getElementById: function(id) {
                namespace[id] = {style: ''}
                return namespace[id];
            },
        };
        $PAGE_JS
        RunOnLoad();
        // DIV id is string of hexadecimanl values of length 32
        for (key in namespace) {
            if (key.length == 32) {
                print(key);
            }
        }
        print(namespace.workframe2.src);
        " | javascript) ||
        { log_error "error running Javascript in main page"; return 1; }
    log_debug "DIV id: $DIVID"
    log_debug "Dynamic page: $DYNAMIC_PATH"
    DYNAMIC=$(curl -b <(echo "$COOKIES") "$BASE_URL/$DYNAMIC_PATH")
    DYNAMIC_JS=$(echo "$DYNAMIC" | sed -n "/<script/,/<\/script>/p" | tail -n+2 | head -n-1)

    FILE_URL=$(echo "
        function alert(x) {print(x); }
        var namespace = {};
        var parent = {
            document: {
                getElementById: function(id) {
                    namespace[id] = {};
                    return namespace[id];
                },
            },
            aa: function(x, y) { print (x,y);},
        };
        $DYNAMIC_JS
        dz();
        print(namespace['$DIVID'].innerHTML);
    " | javascript | parse_attr "href")  ||
        { log_error "error running Javascript in download page"; return 1; }
    echo $FILE_URL
}

# List a mediafire shared file folder URL
# $1: MEDIAFIRE_URL (http://www.mediafire.com/?sharekey=...)
# stdout: list of links
mediafire_list() {
    set -e
    eval "$(process_options mediafire "$MODULE_MEDIAFIRE_LIST_OPTIONS" "$@")"
    URL=$1

    PAGE=$(curl "$URL" | sed "s/>/>\n/g")

    match '/js/myfiles.php/' "$PAGE" ||
        { log_error "not a shared folder"; return 1; }

    local JS_URL=$(echo "$PAGE" | parse 'language=' 'src="\(\/js\/myfiles\.php\/[^"]*\)')
    local DATA=$(curl "http://mediafire.com$JS_URL" | sed "s/;/;\n/g")

    # get number of files
    NB=$(echo "$DATA" | parse '^var oO' "'\([[:digit:]]*\)'")
    NB2=$NB

    log_debug "There is $NB file(s) in the folder"

    # First pass : print debug message
    # es[0]=Array('1','1',3,'te9rlz5ntf1','82de6544620807bf025c12bec1713a48','my_super_file.txt','14958589','14.27','MB','43','02/13/2010', ...
    while [[ "$NB" -gt 0 ]]; do
        ((NB--))
        LINE=$(echo "$DATA" | parse "es\[$NB\]=" "Array(\(.*\));")
        FILENAME=$(echo "$LINE" | cut -d, -f6 | tr -d "'")
        log_debug "$FILENAME"
    done

    # Second pass : print links (stdout)
    NB=$NB2
    while [[ "$NB" -gt 0 ]]; do
        ((NB--))
        LINE=$(echo "$DATA" | parse "es\[$NB\]=" "Array(\(.*\));")
        FID=$(echo "$LINE" | cut -d, -f4 | tr -d "'")
        echo "http://www.mediafire.com/?$FID"
    done

    return 0
}
