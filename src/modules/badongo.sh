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

MODULE_BADONGO_REGEXP_URL="http://\(www\.\)\?badongo\.com/"
MODULE_BADONGO_DOWNLOAD_OPTIONS=""
MODULE_BADONGO_UPLOAD_OPTIONS=
MODULE_BADONGO_DOWNLOAD_CONTINUE=no

# Output a file URL to download from Badongo
#
# badongo_download [MODULE_BADONGO_DOWNLOAD_OPTIONS] BADONGO_URL
#
badongo_download() {
    set -e
    eval "$(process_options bandogo "$MODULE_BADONGO_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    BASEURL="http://www.badongo.com"
    APIURL="${BASEURL}/ajax/prototype/ajax_api_filetemplate.php"

    PAGE=$(curl "$URL")
    match '"recycleMessage">' "$PAGE" &&
        { log_debug "file in recycle bin"; return 254; }
    match '"fileError">' "$PAGE" &&
        { log_debug "file not found"; return 254; }

    detect_javascript >/dev/null || return 1
    PERL_PRG=$(detect_perl) || return 1

    COOKIES=$(create_tempfile)
    TRY=1

    while retry_limit_not_reached || return 3; do
        log_debug "Downloading captcha page (loop $TRY)"
        (( TRY++ ))
        JSCODE=$(curl \
            -F "rs=refreshImage" \
            -F "rst=" \
            -F "rsrnd=$MTIME" \
            "$URL" | sed "s/>/>\n/g")

        ACTION=$(echo "$JSCODE" | parse "form" 'action=\\"\([^\\]*\)\\"') ||
            { log_debug "file not found"; return 254; }

        if test "$CHECK_LINK"; then
            rm -f $COOKIES
            return 255
        fi

        # 200x60 jpeg file
        CAP_IMAGE=$(echo "$JSCODE" | parse '<img' 'src=\\"\([^\\]*\)\\"')
        MTIME="$(date +%s)000"
        CAPTCHA=$(curl $BASEURL$CAP_IMAGE | $PERL_PRG $LIBDIR/strip_threshold.pl 125 | \
            convert - +matte -colorspace gray -level 45%,45% gif:- | \
            show_image_and_tee | ocr upper | sed "s/[^a-zA-Z]//g") ||
                { log_error "unexpected result from OCR"; continue; }

        test "${#CAPTCHA}" -gt 4 && CAPTCHA="${CAPTCHA:0:4}"
        log_debug "Decoded captcha: $CAPTCHA"

        if [ "${#CAPTCHA}" -ne 4 ]; then
            log_debug "Captcha length invalid"
            continue
        fi

        CAP_ID=$(echo "$JSCODE" | parse_form_input_by_name 'cap_id')
        CAP_SECRET=$(echo "$JSCODE" | parse_form_input_by_name 'cap_secret')
        WAIT_PAGE=$(curl -c $COOKIES \
            --data "user_code=${CAPTCHA}&cap_id=${CAP_ID}&cap_secret=$CAP_SECRET" \
            "$ACTION")
        match 'id="link_container"' "$WAIT_PAGE" && break
        log_debug "Wrong captcha"
    done

    log_debug "Correct captcha!"

    # Look for doDownload function
    DYNAMIC_JS1=$(echo "$WAIT_PAGE" | grep 'eval' | sed -n '8p' | \
            sed -e "s/^eval/print/" | javascript) ||
        { log_error "error running Javascript (#1) in download page"; return 1; }
    LINK_PART2=$(echo "$DYNAMIC_JS1" | parse 'location\.href' '+ "\([^"]*\)')

    # Look for window.check_n variable
    DYNAMIC_JS2=$(echo "$WAIT_PAGE" | grep 'eval' | sed -n '3p' | \
            sed -e "s/^eval/print/" | javascript) ||
        { log_error "error running Javascript (#2) in download page"; return 1; }

    WAIT_TIME=$(echo "$DYNAMIC_JS2" | parse 'check_n' 'check_n = \([[:digit:]]\+\)')
    GLF_Z=$(echo "$DYNAMIC_JS2" | tail -n5 | parse 'window\.getFileLinkInitOpt' "'z':'\([^']*\)")
    GLF_H=$(echo "$DYNAMIC_JS2" | tail -n5 | parse 'window\.getFileLinkInitOpt' "'h':'\([^']*\)")
    FILEID="${ACTION##*/}"
    FILETYPE='file'

    # Start remote timer
    DYNAMIC_JS3=$(curl -b $COOKIES \
            --data "id=${FILEID}&type=${FILETYPE}&ext=&f=download%3Ainit&z=${GLF_Z}&h=${GLF_H}" \
            --referer "$ACTION" \
            "$APIURL" | sed -e "s/^eval/print/" | javascript) ||
        { log_error "error running Javascript (#3) in download page"; return 1; }

    # Parse received window['getFileLinkInitOpt'] object
    # Get new values of GLF_Z and GLF_H
    GLF_Z=$(echo "$DYNAMIC_JS3" | parse "'z'" "[[:space:]]'\([^']*\)");
    GLF_H=$(echo "$DYNAMIC_JS3" | parse "'h'" "[[:space:]]'\([^']*\)");
    GLF_T=$(echo "$DYNAMIC_JS3" | parse "'t'" "[[:space:]]'\([^']*\)");

    # Usual wait time is 60 seconds
    wait $((WAIT_TIME)) seconds || return 2

    # Notify remote timer
    DYNAMIC_JS4=$(curl -b $COOKIES \
            --data "id=${FILEID}&type=${FILETYPE}&ext=&f=download%3Acheck&z=${GLF_Z}&h=${GLF_H}&t=${GLF_T}" \
            --referer "$ACTION" \
            "$APIURL" | sed -e "s/^eval/print/" | javascript) ||
        { log_error "error running Javascript (#4) in download page"; return 1; }

    # Parse again received window['getFileLinkInitOpt'] object
    # Get new values of GLF_Z, GLF_H and GLF_T (and escape '!' character)
    GLF_Z=$(echo "$DYNAMIC_JS4" | parse "'z'" "[[:space:]]'\([^']*\)" | replace '!' '%21');
    GLF_H=$(echo "$DYNAMIC_JS4" | parse "'h'" "[[:space:]]'\([^']*\)" | replace '!' '%21');
    GLF_T=$(echo "$DYNAMIC_JS4" | parse "'t'" "[[:space:]]'\([^']*\)" | replace '!' '%21');

    # HTTP GET request
    JSCODE=$(curl -G -b "_gflCur=0" -b $COOKIES \
        --data "rs=getFileLink&rst=&rsrnd=${MTIME}&rsargs[]=0&rsargs[]=yellow&rsargs[]=${GLF_Z}&rsargs[]=${GLF_H}&rsargs[]=${GLF_T}&rsargs[]=${FILETYPE}&rsargs[]=${FILEID}&rsargs[]=" \
        --referer "$ACTION" "$ACTION" | sed "s/>/>\n/g")

    # Example: <a href=\"#\" onclick=\"return doDownload(\'http://www.badongo.com/fd/0101052591990549/CCI97956a6891950969/0\');\">
    LINK_PART1=$(echo "$JSCODE" | parse 'doDownload' "\\\\'\(http[^\\]*\)") ||
            { log_error "can't parse base url"; return 1; }
    FILE_URL="${LINK_PART1}${LINK_PART2}?zenc="

    LAST_PAGE=$(curl -b "_gflCur=0" -b $COOKIES --referer "$ACTION" $FILE_URL)

    # Look for new location.href
    DYNAMIC_JS5=$(echo "$LAST_PAGE" | grep 'eval' | sed -n '5p' | \
            sed -e "s/^eval/print/" | javascript) ||
        { log_error "error running Javascript (#5) in download page"; return 1; }

    LINK_FINAL=$(echo "$DYNAMIC_JS5" | parse 'location\.href' "= '\([^']*\)")
    FILE_URL=$(curl -i -b $COOKIES --referer "$FILE_URL" "${BASEURL}${LINK_FINAL}" | grep_http_header_location)

    rm -f $COOKIES
    test "$FILE_URL" || { log_error "location not found"; return 1; }
    echo "$FILE_URL"
}
