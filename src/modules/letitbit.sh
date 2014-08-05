# Plowshare letitbit module
# Copyright (c) 2012 Plowshare team
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

MODULE_LETITBIT_REGEXP_URL='http://\(\(www\|u[[:digit:]]\+\)\.\)\?letitbit\.net/'

MODULE_LETITBIT_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account"
MODULE_LETITBIT_DOWNLOAD_RESUME=yes
MODULE_LETITBIT_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_LETITBIT_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_LETITBIT_UPLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account (mandatory)"
MODULE_LETITBIT_UPLOAD_REMOTE_SUPPORT=no

MODULE_LETITBIT_LIST_OPTIONS=""
MODULE_LETITBIT_LIST_HAS_SUBFOLDERS=no

MODULE_LETITBIT_DELETE_OPTIONS=""
MODULE_LETITBIT_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
letitbit_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE ERR TYPE EMAIL

    LOGIN_DATA='act=login&login=$USER&password=$PASSWORD'
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/index.php" -b 'lang=en') || return

    # Note: Cookies "pas" + "log" (=login name) get set on successful login
    ERR=$(echo "$PAGE" | parse_tag_quiet 'error-text' 'span')

    if [ -n "$ERR" ]; then
        log_error "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    # Determine account type
    PAGE=$(curl -b "$COOKIE_FILE" -H 'X-Requested-With: XMLHttpRequest' \
        -d 'act=get_attached_passwords' \
        "$BASE_URL/ajax/get_attached_passwords.php") || return

    # There are no attached premium accounts found
    if match 'no attached premium accounts' "$PAGE"; then
        TYPE='free'

    # Note: Contains a table of associated premium codes
    elif match '^[[:space:]]*<th>Premium account</th>' "$PAGE"; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    EMAIL=$(parse_cookie 'log' < "$COOKIE_FILE" | uri_decode) || return
    log_debug "Successfully logged in as $TYPE member '$EMAIL'"

    echo "$TYPE"
}

# Decode the PNG image that contains the obfuscation password
# $1: image file
# stdout: decoded password
letitbit_decode_png() {
    local -r IMAGE_FILE=$1
    local PASS

    # ASCII values of the password chars are stored as the red channel values
    # of all pixels in the PNG
    if check_exec 'pngtopnm'; then
        log_debug 'Using pngtopnm...'
        PASS=$(pngtopnm "$IMAGE_FILE" | last_line)

    elif check_exec 'convert'; then
        local ASCII CHAR VAL
        log_debug 'Using convert...'

        ASCII=$(convert "$IMAGE_FILE" txt:- | \
            parse_all '^[[:digit:]]' 'rgb(\([[:digit:]]\{1,3\}\),') || return

        # convert ASCII values to regular string
        # Source: http://mywiki.wooledge.org/BashFAQ/071
        for VAL in $ASCII; do
            CHAR=$(printf \\$(($VAL/64*100 + $VAL%64/8*10 + $VAL%8)))
            PASS="$PASS$CHAR"
        done

    else
        log_error 'No suitable program found to decode PNG image. Aborting...'
        log_error 'Please install "convert" (ImageMagick) or "pngtopnm" (Netpbm).'
        return $ERR_SYSTEM
    fi

    echo "$PASS"
}

# Decode an obfuscated HTML form
# $1: original form content (including obfuscation script)
# $2: cookie file
# $3: base url
# stdout: decoded input fields of the form
letitbit_decode_form() {
    local -r CRYPT_FORM=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local -r VARIABLE_PREFIX='jac' # look in site source 'eval(jac383("d2lu...'
    local INPUTS IDS VALUES CC LINE RET
    local SCRIPT DEF_SCRIPT PROTO_SCRIPT DEC_SCRIPT DEC_SCRIPT2
    local PREPARE CODE IMAGE_FILE PASS
    local -a ID_ARR VAL_ARR

    detect_javascript || return

    # extract all encrypted form fields (id + value)
    INPUTS=$(echo "$CRYPT_FORM" | break_html_lines_alt | \
        parse_all '<input.*[iI][dD]' '^\(.*\)$') || return
    IDS=$(echo "$INPUTS" | parse_all_attr 'input.*[iI][dD]=' '[iI][dD]') || return
    VALUES=$(echo "$INPUTS" | parse_all_attr 'input.*[iI][dD]=' '[vV][aA][lL][uU][eE]') || return

    # create arrays so we can match id-value pairs
    # Note: taken from 'list_submit' of Plowshare3
    CC=0
    while IFS= read -r LINE; do ID_ARR[CC++]=$LINE; done <<< "$IDS"
    CC=0
    while IFS= read -r LINE; do VAL_ARR[CC++]=$LINE; done <<< "$VALUES"

    if [ ${#ID_ARR[@]} -ne ${#VAL_ARR[@]} ]; then
        log_error 'Error parsing input fields.'
        return $ERR_FATAL
    fi

    # build a JS hashmap for later use: input['id'] = 'value'
    INPUTS="var input = new Object();"
    for CC in "${!ID_ARR[@]}"; do
        INPUTS="$INPUTS input['${ID_ARR[$CC]}'] = '${VAL_ARR[$CC]}';"
    done

    # extract the form decryption script
    SCRIPT=$(echo "$CRYPT_FORM" | tr -d '\n\r' | parse_tag script) || return

    # split up script into general definition part and decrypting part
    DEF_SCRIPT=${SCRIPT%%;;eval(${VARIABLE_PREFIX}*}
    DEC_SCRIPT=${SCRIPT:$(( ${#DEF_SCRIPT} + 2))}

    # optimize to improve compatibility + save time and computing power
    # first part of DEF_SCRIPT is (hopefully) static and decodes to PROTO_SCRIPT
    DEF_SCRIPT="var ${VARIABLE_PREFIX}${DEF_SCRIPT#*;;var ${VARIABLE_PREFIX}}"
    PROTO_SCRIPT='String.prototype.sort=function(){return this.split("").sort().join("")};
String.prototype.ord=function(){return this.charCodeAt(0)};
var EOL=function(){return (1).chr()};
String.prototype.str_split=function(a){var b=[],pos=0,len=this.length;while(pos<len){b.push(this.slice(pos,pos+=a))}return b};
Number.prototype.chr=function(){return String.fromCharCode(this)};'

    # only part 2 (of 2) from decrypt script is really needed
    DEC_SCRIPT=${DEC_SCRIPT#*;}
    DEC_SCRIPT=${DEC_SCRIPT/eval/print}

    # deobfuscate the second part/decryption script
    DEC_SCRIPT2=$(echo "var window = new Object(); window.__jsp_list = new Array(); $PROTO_SCRIPT ; $DEF_SCRIPT ; $DEC_SCRIPT ;" | javascript | tr -d '\n\r' | parse . '\(var .\+);\)}') || return

    CODE=$(echo "$DEC_SCRIPT2" | parse . ", '\([[:alnum:]]\+\)', 'jsprotect") || return
    log_debug "Code: '$CODE'"

    # get image file that encodes the password
    IMAGE_FILE=$(create_tempfile '.png') || return
    RET=''
    curl -b "$COOKIE_FILE" -b 'lang=en' -o "$IMAGE_FILE" --get -d "n=$CODE" \
        -d "r=$(random js)" "$BASE_URL/jspimggen.php" || RET=$?

    if [ -n "$RET" ]; then
        rm -f "$IMAGE_FILE"
        return $RET
    fi

    # extract the password from the image
    PASS=$(letitbit_decode_png "$IMAGE_FILE") || RET=$?
    log_debug "Pass: '$PASS'"
    rm -f "$IMAGE_FILE"
    [ -n "$RET" ] && return $RET

    # acknowledge password at server
    curl -b "$COOKIE_FILE" -b 'lang=en' --get -d 'stat=1' -d 'text=' \
        -d "r=$(random js)" "$BASE_URL/jspimggen.php" || return

    # obfuscated strings are hidden within the 'value' attributes of the 'input'
    # tags and unscrambled by (hopefully!) static JS code - a simplified version
    # of which is used here
    PREPARE="var pass = '$PASS';
function explainJSPForm(dummy1, dummy2, dummy3, list, pass, decoder) {
    var get_value = function (id) {
        try       { return input[id]; }
        catch (e) { return null; }
    };

    var get_values = function (ids) {
        var r = [];
        for (var i = 0; i < ids.length; ++i) {
            r.push(get_value(ids[i]));
        }
        return r.join('');
    };

    list = list.split(';');
    for (var i = 0; i < list.length; ++i) {
        var item = list[i].split('=');
        if (item.length == 1) { item[1] = ''; }
        var k = get_values(item[0].split(','));
        var v = get_values(item[1].split(','));
        k = decoder(k, pass);
        v = decoder(v, pass);
        print('<input name=\"' + k + '\" value=\"' + v + '\" />');
    }
}"

    # finally, decrypt the form and return the plain version
    echo "$PROTO_SCRIPT ; $DEF_SCRIPT ; $INPUTS ; $PREPARE ; $DEC_SCRIPT2 ;" | javascript
}

# Output a file URL to download from Letitbit.net
# $1: cookie file
# $2: letitbit url
# stdout: real file download link
#         file name
letitbit_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://letitbit.net'
    local PAGE URL ACCOUNT SERVER WAIT CONTROL FILE_NAME
    local FORM FORM_REDIR FORM_UID5 FORM_UID FORM_ID FORM_LIVE FORM_SEO
    local FORM_NAME FORM_PIN FORM_REAL_UID FORM_REAL_NAME FORM_HOST FORM_SERVER
    local FORM_SIZE FORM_FILE_ID FORM_INDEX FORM_DIR FORM_ODIR FORM_DESC
    local FORM_LSA FORM_PAGE FORM_SKYMONK FORM_MD5 FORM_REAL_UID_FREE
    local FORM_SHASH FORM_SPIN FORM_CHECK

    # server redirects "simple links" to real download server
    #
    # simple: http://letitbit.net/download/...
    #         http://www.letitbit.net/download/...
    # real:   http://u29043481.letitbit.net/download/...
    URL=$(curl --head "$2" | grep_http_header_location_quiet)
    [ -n "$URL" ] || URL=$2
    LINK_BASE_URL=${URL%%/download/*}

    if [ -n "$AUTH" ]; then
         ACCOUNT=$(letitbit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Note: Premium users are redirected to a download page
    PAGE=$(curl --location -b "$COOKIE_FILE" -c "$COOKIE_FILE" -b 'lang=en' "$URL") || return

    if match 'File not found\|страница не существует' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi


    if [ "$ACCOUNT" = 'premium' ]; then
        local FILE_LINKS

        FILE_NAME=$(parse_tag_quiet 'File:' 'a' <<< "$PAGE") || return
        FILE_LINKS=$(parse_all_attr_quiet 'Link to the file download' 'href' <<< "$PAGE") || return

        if [ -z "$FILE_NAME" -o -z "$FILE_LINKS" ]; then
            log_error 'Could not retrieve premium link. Do you have enough points?'
            return $ERR_FATAL
        fi

        # Note: The page performs some kind of verification on all links,
        # but we try to do without this for now and just use the 1st link.
        echo "$FILE_LINKS" | first_line
        echo "$FILE_NAME"
        return 0
    fi

    # anon/free account download
    FORM=$(grep_form_by_id "$PAGE" 'ifree_form') || return
    FORM=$(letitbit_decode_form "$FORM" "$COOKIE_FILE" "$LINK_BASE_URL") || return
    log_debug "Plain form: $FORM"

    FORM_REDIR=$(parse_form_input_by_name 'redirect_to_pin' <<< "$FORM") || return
    FORM_UID5=$(parse_form_input_by_name 'uid5' <<< "$FORM") || return
    FORM_UID=$(parse_form_input_by_name 'uid' <<< "$FORM") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM") || return
    FORM_LIVE=$(parse_form_input_by_name 'live' <<< "$FORM") || return
    FORM_SEO=$(parse_form_input_by_name 'seo_name' <<< "$FORM") || return
    FORM_NAME=$(parse_form_input_by_name 'name' <<< "$FORM") || return
    FORM_PIN=$(parse_form_input_by_name 'pin' <<< "$FORM") || return
    FORM_REAL_UID=$(parse_form_input_by_name 'realuid' <<< "$FORM") || return
    FORM_REAL_NAME=$(parse_form_input_by_name 'realname' <<< "$FORM") || return
    FORM_HOST=$(parse_form_input_by_name 'host' <<< "$FORM") || return
    FORM_SERVER=$(parse_form_input_by_name_quiet 'ssserver' <<< "$FORM")
    FORM_SIZE=$(parse_form_input_by_name 'sssize' <<< "$FORM") || return
    FORM_FILE_ID=$(parse_form_input_by_name 'file_id' <<< "$FORM") || return
    FORM_INDEX=$(parse_form_input_by_name 'index' <<< "$FORM") || return
    FORM_DIR=$(parse_form_input_by_name_quiet 'dir' <<< "$FORM")
    FORM_ODIR=$(parse_form_input_by_name_quiet 'optiondir' <<< "$FORM")
    FORM_DESC=$(parse_form_input_by_name 'desc' <<< "$FORM") || return
    FORM_LSA=$(parse_form_input_by_name 'lsarrserverra' <<< "$FORM") || return
    FORM_PAGE=$(parse_form_input_by_name_quiet 'page' <<< "$FORM")
    FORM_SKYMONK=$(parse_form_input_by_name 'is_skymonk' <<< "$FORM") || return
    FORM_MD5=$(parse_form_input_by_name 'md5crypt' <<< "$FORM") || return
    FORM_REAL_UID_FREE=$(parse_form_input_by_name 'realuid_free' <<< "$FORM") || return
    FORM_SPIN=$(parse_form_input_by_name 'slider_pin' <<< "$FORM") || return
    FORM_SHASH=$(parse_form_input_by_name 'slider_hash' <<< "$FORM") || return
    FORM_CHECK=$(parse_form_input_by_name '__jspcheck' <<< "$FORM") || return

    # 1) get advertising page
    # Note: Only needed to update cookies.
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' -c "$COOKIE_FILE"               \
        --referer "$URL"        -d 'tpl_d4=d4_plain' -d 'tpl_d3=d3_skymonk'    \
        -d "redirect_to_pin=$FORM_REDIR" -d "uid5=$FORM_UID5"                  \
        -d "uid=$FORM_UID"      -d "id=$FORM_ID"     -d "live=$FORM_LIVE"      \
        -d "seo_name=$FORM_SEO" -d "name=$FORM_NAME" -d "pin=$FORM_PIN"        \
        -d "realuid=$FORM_REAL_UID"      -d "realname=$FORM_REAL_NAME"         \
        -d "host=$FORM_HOST"             -d "ssserver=$FORM_SERVER"            \
        -d "sssize=$FORM_SIZE"           -d "file_id=$FORM_FILE_ID"            \
        -d "index=$FORM_INDEX"  -d "dir=$FORM_DIR"   -d "optiondir=$FORM_ODIR" \
        -d "desc=$FORM_DESC"             -d "lsarrserverra=$FORM_LSA"          \
        -d "page=$FORM_PAGE"             -d "is_skymonk=$FORM_SKYMONK"         \
        -d "md5crypt=$FORM_MD5"          -d "realuid_free=$FORM_REAL_UID_FREE" \
        -d "slider_pin=$FORM_SPIN"       -d "slider_hash=$FORM_SHASH"          \
        -d "__jspcheck=$FORM_CHECK" "$LINK_BASE_URL/born_iframe.php") || return

    # 2) get download request page
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' -c "$COOKIE_FILE"               \
        --referer "$LINK_BASE_URL/born_iframe.php"                             \
        -d 'tpl_d4=d4_plain'    -d 'tpl_d3=d3_skymonk'                         \
        -d "redirect_to_pin=$FORM_REDIR" -d "uid5=$FORM_UID5"                  \
        -d "uid=$FORM_UID"      -d "id=$FORM_ID"     -d "live=$FORM_LIVE"      \
        -d "seo_name=$FORM_SEO" -d "name=$FORM_NAME" -d "pin=$FORM_PIN"        \
        -d "realuid=$FORM_REAL_UID"      -d "realname=$FORM_REAL_NAME"         \
        -d "host=$FORM_HOST"             -d "ssserver=$FORM_SERVER"            \
        -d "sssize=$FORM_SIZE"           -d "file_id=$FORM_FILE_ID"            \
        -d "index=$FORM_INDEX"  -d "dir=$FORM_DIR"   -d "optiondir=$FORM_ODIR" \
        -d "desc=$FORM_DESC"             -d "lsarrserverra=$FORM_LSA"          \
        -d "page=$FORM_PAGE"             -d "is_skymonk=$FORM_SKYMONK"         \
        -d "md5crypt=$FORM_MD5"          -d "realuid_free=$FORM_REAL_UID_FREE" \
        -d "slider_pin=$FORM_SPIN"       -d "slider_hash=$FORM_SHASH"          \
        -d "__jspcheck=$FORM_CHECK" "$LINK_BASE_URL/download3.php") || return

    # 3) parse wait time and wait
    WAIT=$(echo "$PAGE" | parse_tag 'Wait for Your turn' 'span') || return
    wait $((WAIT + 1)) || return

    # 4) check download (Note: dummy '-d" to force a POST request)
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' -d '' \
        -H 'X-Requested-With: XMLHttpRequest'        \
        --referer "$LINK_BASE_URL/download3.php"     \
        "$LINK_BASE_URL/ajax/download3.php") || return

    if [ "$PAGE" != '1' ]; then
        # daily limit reached!?
        log_error "Unexpected response: $PAGE"
        return $ERR_FATAL
    fi

    # 5) confirm free download
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' -c "$COOKIE_FILE"               \
        -d 'tpl_d3=d3_skymonk'                                                 \
        -d "redirect_to_pin=$FORM_REDIR" -d "uid5=$FORM_UID5"                  \
        -d "uid=$FORM_UID"      -d "id=$FORM_ID"     -d "live=$FORM_LIVE"      \
        -d "seo_name=$FORM_SEO" -d "name=$FORM_NAME" -d "pin=$FORM_PIN"        \
        -d "realuid=$FORM_REAL_UID"      -d "realname=$FORM_REAL_NAME"         \
        -d "host=$FORM_HOST"             -d "ssserver=$FORM_SERVER"            \
        -d "sssize=$FORM_SIZE"           -d "file_id=$FORM_FILE_ID"            \
        -d "index=$FORM_INDEX"  -d "dir=$FORM_DIR"   -d "optiondir=$FORM_ODIR" \
        -d "desc=$FORM_DESC"             -d "lsarrserverra=$FORM_LSA"          \
        -d "page=$FORM_PAGE"             -d "is_skymonk=$FORM_SKYMONK"         \
        -d "md5crypt=$FORM_MD5"          -d "realuid_free=$FORM_REAL_UID_FREE" \
        -d "slider_pin=$FORM_SPIN"       -d "slider_hash=$FORM_SHASH"          \
        -d "__jspcheck=$FORM_CHECK" "$LINK_BASE_URL/download3.php") || return

    # Note: Site adds an additional "control field" to the usual ReCaptcha stuff
    CONTROL=$(parse 'var[[:space:]]\+recaptcha_control_field' \
        "=[[:space:]]\+'\([^']\+\)';" <<< "$PAGE") || return

    # Solve recaptcha
    local PUBKEY WCI CHALLENGE WORD CONTROL ID
    PUBKEY='6Lc9zdMSAAAAAF-7s2wuQ-036pLRbM0p8dDaQdAM'
    WCI=$(recaptcha_process $PUBKEY)
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    # Note: "recaptcha_control_field" *must* be encoded properly
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en'    \
        --referer "$LINK_BASE_URL/download3.php"  \
        -H 'X-Requested-With: XMLHttpRequest'     \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD"       \
        --data-urlencode "recaptcha_control_field=$CONTROL" \
        "$LINK_BASE_URL/ajax/check_recaptcha.php") || return

    # Server response should contain multiple URLs if successful
    if ! match 'http' "$PAGE"; then
        if [ "$PAGE" = 'error_wrong_captcha' ]; then
            log_error 'Wrong captcha'
            captcha_nack "$ID"
            return $ERR_CAPTCHA

        elif [ "$PAGE" = 'error_free_download_blocked' ]; then
            # We'll take it literally and wait till the next day
            local HOUR MIN TIME

            # Get current UTC time, prevent leading zeros
            TIME=$(date -u +'%k:%M') || return
            HOUR=${TIME%:*}
            MIN=${TIME#*:}

            log_error 'Daily limit (1 download per day) reached.'
            echo $(( ((23 - HOUR) * 60 + (61 - ${MIN#0}) ) * 60 ))
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        log_error "Unexpected remote error: $PAGE"
        return $ERR_FATAL
    fi

    log_debug 'Correct captcha'
    captcha_ack "$ID"

    # Response contains multiple possible download links, we just pick the first
    echo "$PAGE" | parse . '"\(http:[^"]\+\)"' || return
    echo "$FORM_NAME"
}

# Upload a file to Letitbit.net
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: letitbit download link
#         letitbit delete link
letitbit_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://letitbit.net'
    local PAGE SIZE MAX_SIZE UPLOAD_SERVER MARKER STATUS_URL
    local FORM_HTML FORM_OWNER FORM_PIN FORM_BASE FORM_HOST

    # Login (don't care for account type)
    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS
    letitbit_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" > /dev/null || return

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' "$BASE_URL") || return
    FORM_HTML=$(grep_form_by_id "$PAGE" 'upload_form') || return

    MAX_SIZE=$(echo "$FORM_HTML" | parse_form_input_by_name 'MAX_FILE_SIZE') || return
    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt "$MAX_SIZE" ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    FORM_OWNER=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'owner')
    FORM_PIN=$(echo "$FORM_HTML" | parse_form_input_by_name 'pin') || return
    FORM_BASE=$(echo "$FORM_HTML" | parse_form_input_by_name 'base') || return
    FORM_HOST=$(echo "$FORM_HTML" | parse_form_input_by_name 'host') || return

    UPLOAD_SERVER=$(echo "$PAGE" | parse 'var[[:space:]]\+ACUPL_UPLOAD_SERVER' \
        "=[[:space:]]\+'\([^']\+\)';") || return

    # marker/nonce is generated like this (from http://letitbit.net/acuploader/acuploader2.js)
    #
    # function randomString( _length ) {
    #   var chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXTZabcdefghiklmnopqrstuvwxyz';
    #   ... choose <_length_> random elements from array above ...
    # }
    # ...
    # <marker> = (new Date()).getTime().toString(16).toUpperCase() + '_' + randomString( 40 );
    #
    # example: 13B18CC2A5D_cwhOyTuzkz7GOsdU9UzCwtB0J9GSGXJCsInpctVV
    MARKER=$(printf "%X_%s" "$(date +%s000)" "$(random Ll 40)") || return

    # Upload local file
    PAGE=$(curl_with_log -b "$COOKIE_FILE" -b 'lang=en' \
        -F "MAX_FILE_SIZE=$MAX_SIZE" \
        -F "owner=$FORM_OWNER"       \
        -F "pin=$FORM_PIN"           \
        -F "base=$FORM_BASE"         \
        -F "host=$FORM_HOST"         \
        -F "file0=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
        "http://$UPLOAD_SERVER/marker=$MARKER") || return

    if [ "$(echo "$PAGE" | parse_json_quiet 'code')" -ne 200 ]; then
        log_error "Unexpected response: $PAGE"
        return $ERR_FATAL
    fi

    # Get upload stats/result URL
    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' --get \
        -d "srv=$UPLOAD_SERVER" -d "uid=$MARKER"     \
        "$BASE_URL/acupl_proxy.php") || return

    STATUS_URL=$(echo "$PAGE" | parse_json_quiet 'post_result')

    if [ -z "STATUS_URL" ]; then
        log_error "Unexpected response: $PAGE"
        return $ERR_FATAL
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=en' "$STATUS_URL") || return

    # extract + output download link + delete link
    echo "$PAGE" | parse "$BASE_URL/download/" \
        '<textarea[^>]*>\(http.\+html\)$' || return
    echo "$PAGE" | parse "$BASE_URL/download/delete" \
        '<div[^>]*>\(http.\+html\)<br/>' || return
}

# Delete a file on Letitbit.net
# $1: cookie file
# $2: letitbit.net (delete) link
letitbit_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://letitbit.net'
    local DEL_PART PAGE

    # http://letitbit.net/download/delete15623193_0be902ba49/70662.717a170fc1bf0620a7f62fde1975/worl.html
    if ! match 'download/delete' "$URL"; then
        log_error 'This is not a delete link.'
        return $ERR_FATAL
    fi

    # Check (manually) if file exists
    # remove "delete15623193_0be902ba49/" to get normal download link
    DEL_PART=$(echo "$URL" | parse . '\(delete[^/]\+\)') || return
    PAGE=$(curl -L -b 'lang=en' "${URL/$DEL_PART\//}") || return

    if match 'File not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    curl -L -b 'lang=en' -c "$COOKIE_FILE" -o /dev/null "$URL" || return

    # Solve recaptcha
    local PUBKEY WCI CHALLENGE WORD CONTROL ID
    PUBKEY='6Lc9zdMSAAAAAF-7s2wuQ-036pLRbM0p8dDaQdAM'
    WCI=$(recaptcha_process $PUBKEY)
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    PAGE=$(curl --referer "$URL" -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest'      \
        -d "recaptcha_challenge_field=$CHALLENGE"  \
        -d "recaptcha_response_field=$WORD"        \
        "$BASE_URL/ajax/check_recaptcha2.php") || return

    case "$PAGE" in
        ok)
            captcha_ack "$ID"
            return 0
            ;;
        error_wrong_captcha)
            log_error 'Wrong captcha'
            captcha_nack "$ID"
            return $ERR_CAPTCHA
            ;;
        *)
            log_error "Unexpected response: $PAGE"
            return $ERR_FATAL
            ;;
    esac
}

# List an Letitbit.net shared file folder URL
# $1: letitbit.net folder url
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
letitbit_list() {
    local URL=$1
    local PAGE LINKS NAMES

    # check whether it looks like a folder link
    if ! match "${MODULE_LETITBIT_REGEXP_URL}folder/" "$URL"; then
        log_error 'This is not a directory list.'
        return $ERR_FATAL
    fi

    test "$2" && log_debug "letitbit does not display sub folders"

    PAGE=$(curl -L "$URL") || return

    LINKS=$(echo "$PAGE" | parse_all_attr 'target="_blank"' 'href')
    NAMES=$(echo "$PAGE" | parse_all_tag 'target="_blank"' 'font')

    test "$LINKS" || return $ERR_LINK_DEAD

    list_submit "$LINKS" "$NAMES" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: Letitbit url
# $3: requested capability list
# stdout: 1 capability per line
letitbit_probe() {
    local -r REQ_IN=$3
    local -r AUTH_CODE='dKvvqMCW8'
    local -r BASE_URL='http://api.letitbit.net'
    local URL QUERY JSON REQ_OUT

    # server redirects "simple links" to real download server
    URL=$(curl --head "$2" | grep_http_header_location_quiet)
    [ -n "$URL" ] || URL=$2

    # Using official API (http://api.letitbit.net/reg/static/api.pdf)
    QUERY=$(printf 'r=["%s",["download/info",{"link":"%s"}]]' "$AUTH_CODE" "$URL")
    JSON=$(curl -d "$QUERY" "$BASE_URL/json") || return

    # Check for API errors
    case $(parse_json 'status' <<< "$JSON") in
        'OK')
            ;; # NOP
        'FAIL')
            log_error "Error: $(parse_json 'data' <<< "$JSON")"
            return $ERR_FATAL
            ;;
        *)
            log_error "Unexpected status: $JSON"
            return $ERR_FATAL
            ;;
    esac

    # Check for deleted files (API sends empty reply)
    if [[ $JSON = *'"data":[[]]'* ]]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_json 'name' <<< "$JSON"
        REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        parse_json 'size' <<< "$JSON"
        REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *h* ]]; then
        parse_json 'md5' <<< "$JSON"
        REQ_OUT="${REQ_OUT}h"
    fi

    echo $REQ_OUT
}
