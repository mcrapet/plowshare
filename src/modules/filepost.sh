# Plowshare filepost.com module
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

MODULE_FILEPOST_REGEXP_URL='https\?://\(fp\.io\|\(www\.\)\?filepost\.com\)/'

MODULE_FILEPOST_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account"
MODULE_FILEPOST_DOWNLOAD_RESUME=yes
MODULE_FILEPOST_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FILEPOST_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FILEPOST_UPLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account (mandatory)"
MODULE_FILEPOST_UPLOAD_REMOTE_SUPPORT=no

MODULE_FILEPOST_DELETE_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account (mandatory)"

MODULE_FILEPOST_LIST_OPTIONS=""
MODULE_FILEPOST_LIST_HAS_SUBFOLDERS=yes

MODULE_FILEPOST_PROBE_OPTIONS=""

# Static function. Proceed with login (free or premium)
# $1: authentication
# $2: cookie file
# $3: base URL
# $4: SID (parsed from cookie)
filepost_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local -r SID=$4
    local LOGIN_DATA PAGE STATUS NAME TYPE

    LOGIN_DATA='email=$USER&password=$PASSWORD&remember=on&recaptcha_response_field='
    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/general/login_form/?SID=$SID&JsHttpRequest=$(date +%s0000)-xml" \
        -b "$COOKIE_FILE") || return

    # "JsHttpRequest" is important to get JSON answers, if unused, we get an
    # extra cookie entry named "error" (in case of incorrect login)

    # This IP address has been blocked on our service due to some fraudulent activity.
    if match 'IP address has been blocked on our service' "$PAGE"; then
        log_error 'Your IP/account is blocked by the server.'
        return $ERR_FATAL

    # Sometimes prompts for reCaptcha (like depositfiles)
    # {"id":"1234","js":{"answer":{"captcha":true}},"text":""}
    elif match_json_true 'captcha' "$PAGE"; then
        log_debug 'Captcha solving required for login'

        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6Leu6cMSAAAAAFOynB3meLLnc9-JYi-4l94A6cIE'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

        LOGIN_DATA="email=\$USER&password=\$PASSWORD&remember=on&recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD"
        PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/general/login_form/?SID=$SID&JsHttpRequest=$(date +%s0000)-xml" \
            -b "$COOKIE_FILE") || return

        # {"id":"1234","js":{"answer":{"success":true},"redirect":"http:\/\/filepost.com\/"},"text":""}
        if match_json_true 'success' "$PAGE"; then
            log_debug 'Correct captcha'
            captcha_ack $ID

        # {"id":"1234","js":{"error":"Incorrect e-mail\/password combination"},"text":""}
        elif match 'Incorrect e-mail' "$PAGE"; then
            captcha_ack $ID
            return $ERR_LOGIN_FAILED

        # {"id":"1234","js":{"answer":{"captcha":true},"error":"The code you entered is incorrect. Please try again."},"text":""}
        elif match 'The code you entered is incorrect' "$PAGE"; then
            captcha_nack $ID
            return $ERR_CAPTCHA

        else
            log_error "Unexpected result: $PAGE"
            return $ERR_FATAL
        fi
    fi

    # If successful, two entries are added into cookie file: u and remembered_user
    STATUS=$(parse_cookie_quiet 'remembered_user' < "$COOKIE_FILE")
    [ -z "$STATUS" ] && return $ERR_LOGIN_FAILED

    # Determine account type
    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return
    NAME=$(parse_tag 'Welcome, ' 'b' <<< "$PAGE") || return

    if match '<li>Account type:[[:space:]]*<span>Free</span></li>' "$PAGE"; then
        TYPE='free'
    # Note: educated guessing for now
    elif match '<li>Account type: <span>Premium</span></li>' "$PAGE"; then
        TYPE='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    log_debug "Successfully logged in as $TYPE member '$NAME'"
    echo "$TYPE"
}

# Switch language to english
# $1: cookie file
# $2: base URL
filepost_switch_lang() {
    curl -c "$1" -d 'language=1' -d "JsHttpRequest=$(date +%s0000)-xml" \
        "$2/general/select_language/" -o /dev/null || return
}

# $1: cookie file
# $2: filepost.com url
# stdout: real file download link
filepost_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='https://filepost.com'
    local URL PAGE SID FILE_NAME JSON CODE FILE_PASS TID JS_URL WAIT ROLE

    # Site redirects all possible urls of a file to the canonical one
    URL=$(curl --head --location "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2

    filepost_switch_lang "$COOKIE_FILE" "$BASE_URL" || return
    SID=$(parse_cookie 'SID' < "$COOKIE_FILE") || return

    if [ -n "$AUTH" ]; then
        ROLE=$(filepost_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" "$SID") || return
    fi

    PAGE=$(curl -L -b "$COOKIE_FILE" "$URL") || return

    # <h1 title="">File not found</h1>
    match 'File not found' "$PAGE" && return $ERR_LINK_DEAD


    # We are sorry, the server where this file is located is currently unavailable, but should be recovered soon. Please try to download this file later.
    if matchi 'is currently unavailable' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE

    # Files over 1024MB can be downloaded by premium<br/ >members only. Please upgrade to premium to<br />download this file at the highest speed.
    elif match 'Files over .\+ can be downloaded by premium' "$PAGE"; then
        return $ERR_SIZE_LIMIT_EXCEEDED

    elif matchi 'premium membership is required' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FILE_NAME=$(parse '<title>' ': Download \(.*\) - fast' <<< "$PAGE")

    if [ "$ROLE" = 'premium' ]; then
        FILE_URL=$(parse '/get_file/' "('\(http[^']*\)" <<< "$PAGE") || return

        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0
    fi

    CODE=$(parse '/files/' 'files/\([^/]*\)' <<< "$URL") || return
    TID=t$(random d 4)
    JS_URL="$BASE_URL/files/get/?SID=$SID&JsHttpRequest=$(date +%s0000)-xml"

    log_debug "code=$CODE, sid=$SID, tid=$TID"

    JSON=$(curl --data \
        "action=set_download&code=$CODE&token=$TID" "$JS_URL") || return

    # {"id":"12345","js":{"answer":{"wait_time":"60"}},"text":""}
    WAIT=$(parse 'wait_time' 'wait_time"[[:space:]]*:[[:space:]]*"\([^"]*\)' <<< "$JSON")

    if [ -z "$WAIT" ]; then
        log_error 'Cannot get wait time'
        log_debug "$JSON"
        return $ERR_FATAL
    fi

    wait $WAIT seconds || return

    # reCaptcha part
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6Leu6cMSAAAAAFOynB3meLLnc9-JYi-4l94A6cIE'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    JSON=$(curl -d "code=$CODE" -d "file_pass=$FILE_PASS" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" -d "token=$TID" \
        "$JS_URL") || return

    # {"id":"12345","js":{"error":"You entered a wrong CAPTCHA code. Please try again."},"text":""}
    if matchi 'wrong CAPTCHA code' "$JSON"; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    # {"id":"12345","js":{"answer":{"link":"http:\/\/fs122.filepost.com\/get_file\/...\/"}},"text":""}
    # {"id":"12345","js":{"error":"f"},"text":""}
    local ERR=$(parse_json_quiet 'error' <<<  "$JSON")
    if [ -n "$ERR" ]; then
        # You still need to wait for the start of your download"
        if match 'need to wait' "$ERR"; then
            return $ERR_LINK_TEMP_UNAVAILABLE
        else
            log_error "Unexpected remote error: $ERR"
            return $ERR_FATAL
        fi
    fi

    FILE_URL=$(parse_json 'link' <<< "$JSON") || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to filepost
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download_url
filepost_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local BASE_URL='https://filepost.com'
    local PAGE SERVER MAX_SIZE SID DONE_URL DATA FID

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS
    filepost_switch_lang "$COOKIE_FILE" "$BASE_URL" || return
    SID=$(parse_cookie_quiet 'SID' < "$COOKIE_FILE") || return
    filepost_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" "$SID" > /dev/null || return

    PAGE=$(curl -L -b "$COOKIE_FILE" "$BASE_URL/files/upload") || return
    SERVER=$(parse '[[:space:]]upload_url' ":[[:space:]]'\([^']*\)" <<< "$PAGE") || return
    MAX_SIZE=$(parse 'max_file_size:' ':[[:space:]]*\([^,]\+\)' <<< "$PAGE") || return

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    DONE_URL=$(parse 'done_url:' ":[[:space:]]*'\([^']*\)" <<< "$PAGE") || return

    DATA=$(curl_with_log --user-agent 'Shockwave Flash' \
        -F "Filename=$DEST_FILE" \
        -F "SID=$SID" \
        -F "file=@$FILE;filename=$DEST_FILE" \
        -F 'Upload=Submit Query' \
        "$SERVER") || return

    # new Object({"answer":"4c8e89fa"})
    FID=$(parse_json 'answer' <<< "$DATA") || return
    log_debug "file id: $FID"

    # Note: Account cookie required here
    DATA=$(curl -b "$COOKIE_FILE" -b "SID=$SID" "$DONE_URL$FID") || return

    parse_attr 'id="down_link' 'value' <<< "$DATA"|| return
    parse_attr 'id="edit_link' 'value' <<< "$DATA" || return
}

# Delete a file from FilePost
# $1: cookie file
# $2: filepost (download) link
filepost_delete() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='https://filepost.com'
    local PAGE FILE_ID SID

    if ! match '/files/edit/' "$URL"; then
        log_error 'This is not a delete link'
        return $ERR_FATAL
    fi

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS
    filepost_switch_lang "$COOKIE_FILE" "$BASE_URL" || return
    SID=$(parse_cookie_quiet 'SID' < "$COOKIE_FILE") || return
    filepost_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" "$SID" > /dev/null || return

    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

    # <span><b><ins class="delete">Delete File</ins></b></span>
    match '<ins class="delete">Delete File</ins>' "$PAGE" || return $ERR_LINK_DEAD

    FILE_ID=$(parse_form_input_by_name 'items\[files\]' <<< "$PAGE") || return

    # Deletion via edit/delete page doesn't work, so we use file manager instead
    # Note: Parameters concerning file order etc. are not required
    PAGE=$(curl -b "$COOKIE_FILE" --referer "$BASE_URL/files/manager/" \
        -d 'action=delete_items' -d "items[files][0]=$FILE_ID" \
        "$BASE_URL/files/manager/?SID=$SID&JsHttpRequest=$(date +%s)0000-xml") || return

    # No useful feedback ... check if file is gone
    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return
    match '<ins class="delete">Delete File</ins>' "$PAGE" || return 0

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}

# List a filepost web folder URL
# $1: filepost URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
filepost_list() {
    if ! match 'filepost\.com/folder/' "$1"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    filepost_list_rec "$2" "$1" || return
}

# static recursive function
# $1: recursive flag
# $2: web folder URL
filepost_list_rec() {
    local REC=$1
    local URL=$2
    local PAGE LINKS NAMES RET LINE

    RET=$ERR_LINK_DEAD
    PAGE=$(curl -L "$URL") || return

    if match 'class="dl"' "$PAGE"; then
        LINKS=$(parse_all_attr 'class="dl"' 'href' <<< "$PAGE")
        NAMES=$(parse_all_tag 'class="file \(video\|image\|disk\|archive\)"' 'a' <<< "$PAGE")
        list_submit "$LINKS" "$NAMES" && RET=0
    fi

    if test "$REC"; then
        LINKS=$(parse_all_attr_quiet 'class="file folder"' 'href' <<< "$PAGE")
        while read LINE; do
            test "$LINE" || continue
            log_debug "entering sub folder: $LINE"
            filepost_list_rec "$REC" "$LINE" && RET=0
        done <<< "$LINKS"
    fi

    return $RET
}

# Probe a download URL
# $1: cookie file
# $2: Filepost url
# $3: requested capability list
# stdout: 1 capability per line
filepost_probe() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r REQ_IN=$3
    local -r BASE_URL='https://filepost.com'
    local PAGE REQ_OUT FILE_SIZE

    filepost_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -b "$COOKIE_FILE" --data-urlencode "urls=$URL" \
        "$BASE_URL/files/checker/?JsHttpRequest=$(date +%s0000)-xml") || return

    match 'Active' "$PAGE" || return $ERR_LINK_DEAD
    REQ_OUT=c

    # Get rid of escaping
    PAGE=$(replace_all '\' '' <<< "$PAGE")

    if [[ $REQ_IN = *i* ]]; then
        parse_json 'id' <<< "$PAGE" && REQ_OUT="${REQ_OUT}i"
    fi

    if [[ $REQ_IN = *f* ]]; then
        # Parse file name from full URL (Note the trailing slash!)
        #   https://filepost.com/files/123/xyz/
        parse '' 'files/[^/]\+/\([^/]\+\)/' <<< "$PAGE" | uri_decode &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '.' \
            '<td>\([[:digit:].]\+[[:space:]][KMG]\?B\)\(ytes\)\?</td>' <<< "$PAGE") &&
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
