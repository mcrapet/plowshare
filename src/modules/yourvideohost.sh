# Plowshare yourvideohost.com module
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

MODULE_YOURVIDEOHOST_REGEXP_URL='https\?://\(www\.\)\?yourvideohost\.com/'

MODULE_YOURVIDEOHOST_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,Premium account"
MODULE_YOURVIDEOHOST_DOWNLOAD_RESUME=yes
MODULE_YOURVIDEOHOST_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_YOURVIDEOHOST_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_YOURVIDEOHOST_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: credentials string
# $2: cookie file
# $3: base url
yourvideohost_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT NAME ERR

    LOGIN_DATA='op=login&redirect=&login=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL") || return

    # Set-Cookie: login xfsts
    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -n "$NAME" ]; then
        log_debug "Successfully logged in as $NAME member"
        return 0
    fi

    # Try to parse error
    # <b class='err'>Incorrect Username or Password</b><br>
    ERR=$(parse_tag_quiet 'class=.err.>' b <<< "$LOGIN_RESULT")
    [ -n "$ERR" ] && log_error "Unexpected remote error: $ERR"

    return $ERR_LOGIN_FAILED
}

# Output a yourvideohost file download URL
# $1: cookie file (unused here)
# $2: yourvideohost url
# stdout: real file download link
yourvideohost_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://yourvideohost.com'
    local PAGE FILE_URL WAIT_TIME JS
    local FORM_HTML FORM_OP FORM_ID FORM_USR FORM_REF FORM_FNAME FORM_HASH FORM_SUBMIT

    detect_javascript || return

    if [ -n "$AUTH" ]; then
        yourvideohost_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    else
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_USR=$(parse_form_input_by_name_quiet 'usr_login' <<< "$FORM_HTML")
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_FNAME=$(parse_form_input_by_name 'fname' <<< "$FORM_HTML") || return
    FORM_HASH=$(parse_form_input_by_name 'hash' <<< "$FORM_HTML") || return
    FORM_SUBMIT=$(parse_form_input_by_name 'imhuman' <<< "$FORM_HTML") || return

    # <span id="countdown_str">Wait <span id="cxc">3</span> seconds</span>
    WAIT_TIME=$(parse_tag 'countdown_str' 'span' <<< "$PAGE")
    wait $((WAIT_TIME)) || return

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -d "op=$FORM_OP" -d "id=$FORM_ID" -d "usr_login=$FORM_USR" \
        -d "referer=$FORM_REF" -d "fname=$FORM_FNAME" \
        -d "hash=$FORM_HASH" -d "imhuman=$FORM_SUBMIT" \
        "$URL") || return

    # Obfuscated javascript
    # <script type='text/javascript'>eval(function(p,a,c,k,e,d){ ...
    JS=$(grep_script_by_order "$PAGE" -4) || return
    JS=$(echo "${JS#*>}" | delete_last_line)
    log_debug "js: '$JS'"

    FILE_URL=$(javascript <<< 'empty = function(f) {}
setup = function(opts) {
  for(var key in opts) {
    if (key == "file") {
      print(opts[key]);
      break;
    }
  }
}
var jwplayer = function(tag) {
  return {
    setup: setup,
    onTime: empty,
    onSeek: empty,
    onPlay: empty,
    onComplete: empty,
  };
}
'"$JS") || return

    echo "$FILE_URL"
    echo "$FORM_FNAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: yourvideohost url
# $3: requested capability list
# stdout: 1 capability per line
yourvideohost_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE
    local -r BASE_URL='http://yourvideohost.com/checkfiles.html'

    PAGE=$(curl -b 'lang=english' --referer "$BASE_URL" \
        -d 'op=checkfiles' -d 'process=check' \
        --data-urlencode "list=$URL" "$BASE_URL") || return

    # Feature is broken upstream

    if match 'red.>.* not found!</' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    echo $REQ_OUT
}
