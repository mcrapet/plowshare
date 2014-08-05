# Plowshare hdstream.to module
# Copyright (c) 2014 Plowshare team
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

MODULE_HDSTREAM_TO_REGEXP_URL='https\?://\(www\.\)\?hdstream\.to/'

MODULE_HDSTREAM_TO_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
STREAM,,stream,,Download video stream instead of direct download"
MODULE_HDSTREAM_TO_DOWNLOAD_RESUME=no
MODULE_HDSTREAM_TO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_HDSTREAM_TO_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_HDSTREAM_TO_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
FULL_LINK,,full-link,,Final link includes filename
TITLE,,title,s=TITLE,Set file title
CATEGORY,,category,s=CATEGORY,Set file category - private, public or adult (default: public)
QUALITY,,quality,s=QUALITY,Set stream quality - original, hd, sd or smartphone (default: original)
DL_LEVEL,,level,s=DL_LEVEL,Set downloadable level - all, mb100, mb200, mb450 or premium (default: all)
DL_OFF,,nodownload,,Disallow stream download"

MODULE_HDSTREAM_TO_UPLOAD_REMOTE_SUPPORT=no

MODULE_HDSTREAM_TO_PROBE_OPTIONS=""

# Static function. Proceed with login.
hdstream_to_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local PAGE LOGIN_DATA LOGIN_RESULT LOGIN_CHECK

    LOGIN_DATA='data=%7B%22username%22%3A%22$USER%22%2C+%22password%22%3A%22$PASSWORD%22%7D'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/json/login.php") || return

    LOGIN_CHECK=$(parse_json 'logged_in' <<< "$LOGIN_RESULT") || return
    if [ "$LOGIN_CHECK" != 'true' ]; then
        return $ERR_LOGIN_FAILED
    fi
}

# Output a hdstream.to file download URL and name
# $1: cookie file
# $2: hdstream.to url
# stdout: file download link
#         file name
hdstream_to_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://hdstream.to'

    local PAGE FILE_TOKEN FILE_NAME FILE_SERVER FILE_LOC FILE_URL FILE_CTYPE
    local PREMIUM_T='0'

    if match '/f/' "$URL"; then
        if match '\.html$' "$URL"; then
            FILE_TOKEN=$(parse . 'hdstream\.to/f/.*-\([[:alnum:]]\+\)\.html$' <<< "$URL") || return
        else
            FILE_TOKEN=$(parse . 'hdstream\.to/f/\([[:alnum:]]\+\)$' <<< "$URL") || return
        fi
    else
        FILE_TOKEN=$(parse . 'hdstream\.to/#!f=\([[:alnum:]]\+\)$' <<< "$URL") || return
    fi

    if [ -n "$AUTH" ]; then
        local USERNAME
        local RND=$(random d 10)

        hdstream_to_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return

        split_auth "$AUTH" USERNAME || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            "$BASE_URL/json/userdata.php?user=$USERNAME&ra$RND") || return

        PREMIUM_T=$(parse_json 'premium' <<< "$PAGE") || return

        log_debug "Premium timestamp: '$PREMIUM_T'"
    else
        PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL") || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" \
        "$BASE_URL/json/filelist.php?file=$FILE_TOKEN") || return
    PAGE=$(replace_all '}', $'}\n' <<< "$PAGE") || return

    if ! match "\"token\":\"$FILE_TOKEN\"" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(parse "\"token\":\"$FILE_TOKEN\"" '"name":"\([^"]\+\)' <<< "$PAGE") || return
    # In case of unicode names \u1234
    FILE_NAME=$(echo -e "$FILE_NAME")

    FILE_SERVER=$(parse "\"token\":\"$FILE_TOKEN\"" '"server":"\([^"]\+\)' <<< "$PAGE") || return

    # Bypass limits option (works only for mp4)
    # FILE_HASH=$(parse "\"token\":\"$FILE_TOKEN\"" '"hash":"\([^"]\+\)' <<< "$PAGE") || return
    # FILE_EXT=$(parse "\"token\":\"$FILE_TOKEN\"" '"extension":"\([^"]\+\)' <<< "$PAGE") || return
    #
    # echo "http://s${FILE_SERVER}.hdstream.to/data/${FILE_HASH}.${FILE_EXT}"
    # echo "$FILE_NAME"
    # return 0

    if [ -n "$STREAM" ]; then
        PAGE=$(curl -I -b "$COOKIE_FILE" \
            "http://s${FILE_SERVER}.hdstream.to/send.php?token=$FILE_TOKEN&stream=1") || return

        # 403 if limit is reached or video require premium
        if match '403 Forbidden' "$PAGE"; then
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        if match '404 Not Found' "$PAGE"; then
            log_error 'Unstreamable file. Use direct download.'
            return $ERR_FATAL
        fi

        FILE_CTYPE=$(grep_http_header_content_type <<< "$PAGE") || return

        MODULE_HDSTREAM_TO_DOWNLOAD_RESUME=yes

        if match 'text/html' "$FILE_CTYPE"; then
            # mp4 videos return redirect
            FILE_LOC=$(grep_http_header_location <<< "$PAGE") || return
            FILE_URL="http://s${FILE_SERVER}.hdstream.to/${FILE_LOC}"
        else
            FILE_URL="http://s${FILE_SERVER}.hdstream.to/send.php?token=$FILE_TOKEN&stream=1"
        fi
    else
        if [ "$PREMIUM_T" = '0' ]; then
            PAGE=$(curl -b "$COOKIE_FILE" \
                "$BASE_URL/send.php?visited=$FILE_TOKEN") || return

            WAIT_TIME=$(parse_json 'wait' <<< "$PAGE") || return
            WAIT_TIME=$((WAIT_TIME + 10))
            wait $WAIT_TIME || return

            PAGE=$(curl -I -b "$COOKIE_FILE" -e "$BASE_URL/" \
                "http://s${FILE_SERVER}.hdstream.to/send.php?token=$FILE_TOKEN") || return

            # 403 if limit is reached or video require premium
            if match '403 Forbidden' "$PAGE"; then
                return $ERR_LINK_NEED_PERMISSIONS
            fi
        else
            MODULE_HDSTREAM_TO_DOWNLOAD_RESUME=yes
        fi

        FILE_URL="http://s${FILE_SERVER}.hdstream.to/send.php?token=$FILE_TOKEN"
    fi

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to hdstream.to
# $1: cookie file
# $2: file path or remote url
# $3: remote filename
# stdout: download link
hdstream_to_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://hdstream.to'
    local -r SZ=$(get_filesize "$FILE")

    local UPLOAD_SRV ERROR_CHECK FILE_NAME FILE_TOKEN

    # Defaults
    local CATEGORY_OPT='1'
    local QUALITY_OPT='original'
    local DL_LEVEL_OPT='all'
    local DL_OPT='true'

    # Doesn't work actually, all upload are downloadable
    [ -n "$DL_OFF" ] && DL_OPT='false'

    if [ -n "$DL_LEVEL" ]; then
        if ! match '^all$\|^mb100$\|^mb200$\|^mb450$\|^premium$' "$DL_LEVEL"; then
            log_error 'Unknown download level, allowed: all, mb100, mb200, mb450, premium.'
            return $ERR_BAD_COMMAND_LINE
        fi

        DL_LEVEL_OPT="$DL_LEVEL"
    fi

    if [ -n "$QUALITY" ]; then
        if ! match '^original$\|^hd$\|^sd$\|^smartphone$' "$QUALITY"; then
            log_error 'Unknown quality level, allowed: original, hd, sd, smartphone.'
            return $ERR_BAD_COMMAND_LINE
        fi

        QUALITY_OPT="$QUALITY"
    fi

    if [ -n "$CATEGORY" ]; then
        case "$CATEGORY" in
            'private')
                CATEGORY_OPT='0'
                ;;
            'public')
                CATEGORY_OPT='1'
                ;;
            'adult')
                CATEGORY_OPT='2'
                ;;
            *)
                log_error 'Unknown category type, allowed: private, public, adult.'
                return $ERR_BAD_COMMAND_LINE
                ;;
        esac
    fi

    if [ -n "$AUTH" ]; then
        hdstream_to_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/json/post-file.php?size=$SZ") || return

    ERROR_CHECK=$(parse_json 'error' <<< "$PAGE") || return
    if [ "$ERROR_CHECK" = 'true' ]; then
        log_error 'Failed to get server number.'
        return $ERR_FATAL
    fi

    UPLOAD_SRV=$(parse_json 'server' <<< "$PAGE") || return

    PAGE=$(curl_with_log -b "$COOKIE_FILE" \
        --form-string "title=$TITLE" \
        -F "category=$CATEGORY_OPT" \
        -F "download=$DL_OPT" \
        -F "downloadable=$DL_LEVEL_OPT" \
        -F "stream=$QUALITY_OPT" \
        -F "file=@$FILE;filename=$DEST_FILE" \
        "http://s${UPLOAD_SRV}.hdstream.to/upload/") || return

    ERROR_CHECK=$(parse_json 'existing' <<< "$PAGE") || return
    if [ "$ERROR_CHECK" = 'true' ]; then
        log_error 'Upload failed. File already exists.'
        return $ERR_FATAL
    fi

    ERROR_CHECK=$(parse_json 'empty_tags' <<< "$PAGE") || return
    if [ "$ERROR_CHECK" = 'true' ]; then
        log_error 'Upload failed. File has empty tags.'
        return $ERR_FATAL
    fi

    FILE_TOKEN=$(parse_json 'token' <<< "$PAGE") || return

    if [ -z "$FULL_LINK" ]; then
        echo "$BASE_URL/f/$FILE_TOKEN"
        return 0
    fi

    FILE_NAME=$(parse_json 'file_title' <<< "$PAGE") || return
    if [ "$FILE_NAME" = 'null' ]; then
        FILE_NAME=$(parse_json 'name' <<< "$PAGE") || return
    fi

    # In case of unicode names \u1234
    FILE_NAME=$(echo -e "$FILE_NAME")
    FILE_NAME=${FILE_NAME// - /-}
    FILE_NAME=${FILE_NAME// /-}
    # Strip all special symbols, all characters after first letter are not important
    # anyway redirects to http://hdstream.to/#!f=XXXXXXXX
    # OK:   http://hdstream.to/f/Test.avi-XXXXXXXX.html
    # OK:   http://hdstream.to/f/Tabcabc.abc-XXXXXXXX.html
    # Fail: http://hdstream.to/f/test.avi-XXXXXXXX.html
    FILE_NAME=${FILE_NAME//[\\!@#$%^&*()[\]\{\}:|<>?]/}

    echo "$BASE_URL/f/$FILE_NAME-$FILE_TOKEN.html"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: hdstream.to url
# $3: requested capability list
# stdout: 1 capability per line
hdstream_to_probe() {
    local -r URL=$2
    local -r REQ_IN=$3

    local PAGE ERROR_CHECK FILE_NAME

    PAGE=$(curl \
        -d "check=$URL" \
        'http://hdstream.to/json/check.php') || return

    ERROR_CHECK=$(parse_json 'error' <<< "$PAGE") || return
    if [ "$ERROR_CHECK" = 'true' ]; then
        log_error 'Probe failed. Remote error.'
        return $ERR_FATAL
    fi

    ERROR_CHECK=$(parse_json 'state' <<< "$PAGE") || return
    if [ "$ERROR_CHECK" = 'off' ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        # In case of unicode names \u1234
        FILE_NAME=$(parse_json 'name' <<< "$PAGE") && \
            echo -e "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        parse_json 'size' <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
