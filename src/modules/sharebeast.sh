# Plowshare sharebeast.com module
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

MODULE_SHAREBEAST_REGEXP_URL='http://\(www\.\)\?sharebeast\.com/[[:alnum:]]\+'

MODULE_SHAREBEAST_DOWNLOAD_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_SHAREBEAST_DOWNLOAD_RESUME=yes
MODULE_SHAREBEAST_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_SHAREBEAST_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_SHAREBEAST_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_SHAREBEAST_UPLOAD_REMOTE_SUPPORT=yes

MODULE_SHAREBEAST_DELETE_OPTIONS=""
MODULE_SHAREBEAST_PROBE_OPTIONS=""

# Static function. Proceed with login.
sharebeast_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA LOGIN_RESULT

    LOGIN_DATA='op=login&login=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL" '-i') || return

    LOCATION=$(echo "$LOGIN_RESULT" | grep_http_header_location_quiet)

    if ! match "$BASE_URL/?op=my_files\$" "$LOCATION"; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a sharebeast file download URL
# $1: cookie file
# $2: sharebeast url
# stdout: real file download link
sharebeast_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local PAGE FORM_HTML FORM_ID FORM_RAND

    PAGE=$(curl -c "$COOKIE_FILE" -b 'lang=english' -b "$COOKIE_FILE" "$URL") || return

    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    if match 'Password:</b> <input type="password"' "$PAGE"; then
        log_debug 'File is password protected'

        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand') || return

    PAGE=$(curl -i -b "$COOKIE_FILE" \
        -d 'op=download2' \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d 'referer=' \
        -d 'method_free=' \
        -d 'method_premium=' \
        -d "password=$LINK_PASSWORD" \
        -d 'down_script=1' \
        "$URL") || return

    if match 'Wrong password' "$PAGE"; then
        return $ERR_LINK_PASSWORD_REQUIRED
    fi

    echo "$PAGE" | grep_http_header_location
}

# Upload a file to sharebeast
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
sharebeast_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.sharebeast.com'
    local PAGE FILE_SIZE MAX_SIZE LINK_DL LINK_DEL
    local FORM_HTML FORM_URL
    local FORM_SRV_TMP FORM_SESS
    local UP_URL UP_RND UP_ID UP_TYPE SPACE_USED FILE_ID

    if match_remote_url "$FILE"; then
        # Remote upload requires registration
        if test -z "$AUTH"; then
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    else
        # 500 MiB limit for account users
        if test "$AUTH"; then
            MAX_SIZE=524288000 # 500 MiB
        else
            MAX_SIZE=209715200 # 200 MiB
        fi

        FILE_SIZE=$(get_filesize "$FILE")
        if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
            log_debug "File is bigger than $MAX_SIZE"
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    if test "$AUTH"; then
        sharebeast_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

        if ! match_remote_url "$FILE"; then
            PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=my_files") || return

            # 0.0 Kb of 15 GB
            SPACE_USED=$(echo "$PAGE" | parse '<h2>Used space </h2>' \
                '^[[:space:]]*\([0-9.]\+[[:space:]]*[KMGb]\+\) of ' 1) || return
            SPACE_USED=$(translate_size "$(uppercase "$SPACE_USED")")

            # Check 15GB space limit
            if (( ( 16106127360 - "$SPACE_USED" ) < "$FILE_SIZE" )); then
                log_error 'Not enough space in account folder'
                return $ERR_SIZE_LIMIT_EXCEEDED
            fi
        fi

        UP_TYPE='reg'
    else
        UP_TYPE='anon'
    fi

    UP_RND=$(random d 13)
    UP_URL="$BASE_URL/?op=ajaxUpload&height=580&width=750&modal=true&random=$UP_RND"

    PAGE=$(curl -c "$COOKIE_FILE" -b 'lang=english' -b "$COOKIE_FILE" "$UP_URL") || return

    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_URL=$(echo "$FORM_HTML" | parse_form_action) || return

    FORM_SRV_TMP=$(echo "$FORM_HTML" | parse_form_input_by_name 'srv_tmp_url') || return
    # Will be empty on anon upload
    FORM_SESS=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'sess_id')

    # Initial js code:
    # for (var i = 0; i < 12; i++) UID += '' + Math.floor(Math.random() * 10);
    # form_action = form_action.split('?')[0] + '?upload_id=' + UID + '&js_on=1' + '&utype=' + utype + '&upload_type=' + upload_type;
    # upload_type: file, url
    # utype: anon, reg
    UP_ID=$(random d 12)
    FORM_URL="$FORM_URL$UP_ID&js_on=1&utype=$UP_TYPE"

    # Upload remote file
    if match_remote_url "$FILE"; then
        FORM_URL="$FORM_URL&upload_type=url"

        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -F "upload_type=url" \
            -F "sess_id=$FORM_SESS" \
            -F "srv_tmp_url=$FORM_SRV_TMP" \
            -F "url_mass=$FILE" \
            --form-string "link_rcpt=$TOEMAIL" \
            --form-string "link_pass=$LINK_PASSWORD" \
            -F "tos=1" \
            -F "submit_btn= Upload! " \
            "$FORM_URL") || return
    # Upload local file
    else
        FORM_URL="$FORM_URL&upload_type=file"

        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -F "upload_type=file" \
            -F "sess_id=$FORM_SESS" \
            -F "srv_tmp_url=$FORM_SRV_TMP" \
            -F "file_0=@$FILE;filename=$DESTFILE" \
            -F "file_1=@/dev/null;filename=" \
            --form-string "file_0_descr=$DESCRIPTION" \
            -F "file_0_public=1" \
            --form-string "link_rcpt=$TOEMAIL" \
            --form-string "link_pass=$LINK_PASSWORD" \
            -F "tos=1" \
            -F "submit_btn= Upload! " \
            "$FORM_URL") || return
    fi

    if match 'Max filesize limit exceeded' "$PAGE"; then
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    FILE_ID=$(echo "$PAGE" | parse . "name='fn'>\([^<]\+\)<") || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "fn=$FILE_ID" \
        -d "st=OK" \
        -d "op=upload_result" \
        -d "link_rcpt=$(uri_encode <<< $TOEMAIL)" \
        "$BASE_URL") || return

    LINK_DL=$(echo "$PAGE" | parse_attr '<input.*value="http://www.sharebeast.com/' value) || return
    LINK_DEL=$(echo "$PAGE" | parse_attr '<input.*killcode=' value) || return

    echo "$LINK_DL"
    echo "$LINK_DEL"
}

# Delete a file uploaded to sharebeast
# $1: cookie file (unused here)
# $2: delete url
sharebeast_delete() {
    local -r URL=$2
    local PAGE FILE_ID FILE_DEL_ID

    if ! match '?killcode=[[:alnum:]]\+' "$URL"; then
        log_error 'Invalid URL format'
        return $ERR_BAD_COMMAND_LINE
    fi

    FILE_ID=$(parse . '^.*/\([[:alnum:]]\+\)' <<< "$URL")
    FILE_DEL_ID=$(parse . 'killcode=\([[:alnum:]]\+\)$' <<< "$URL")

    PAGE=$(curl -b 'lang=english' -e "$URL" \
        -d "op=del_file" \
        -d "id=$FILE_ID" \
        -d "del_id=$FILE_DEL_ID" \
        -d "confirm=yes" \
        'http://www.sharebeast.com/') || return

    if match 'File deleted successfully' "$PAGE"; then
        return 0
    elif match 'No such file exist' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match 'Wrong Delete ID' "$PAGE"; then
        log_error 'Wrong delete ID'
    fi

    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: sharebeast url
# $3: requested capability list
# stdout: 1 capability per line
sharebeast_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -b 'lang=english' "$URL") || return

    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '^<h2>' '<h2>\(.*\?\)' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '<div class="inlinfo">Size</div>' \
            '<div class="inlinfo1">\([^<]*\)</div>' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
