# Plowshare oboom.com module
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

MODULE_OBOOM_REGEXP_URL='https\?://\(www\.\)\?oboom\.com/'

MODULE_OBOOM_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_OBOOM_DOWNLOAD_RESUME=no
MODULE_OBOOM_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_OBOOM_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_OBOOM_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
FOLDER,,folder,s=FOLDER,Folder to upload files into
ASYNC,,async,,Asynchronous remote upload (only start upload, don't wait for link)"
MODULE_OBOOM_UPLOAD_REMOTE_SUPPORT=yes

MODULE_OBOOM_LIST_OPTIONS=""
MODULE_OBOOM_LIST_HAS_SUBFOLDERS=yes

MODULE_OBOOM_PROBE_OPTIONS=""

# Static function. Proceed with login.
oboom_login() {
    local -r AUTH=$1
    #local -r COOKIE_FILE=$2
    #local -r BASE_URL=$3

    local PAGE USER PASSWORD JS PASS_PBKDF2 PBKDF2_SCRIPT ACC_SESSION ACC_PREMIUM

    detect_javascript || return

    PBKDF2_SCRIPT='
    /*
     * A JavaScript implementation of the Secure Hash Algorithm, SHA-1, as defined
     * in FIPS 180-1
     * Version 2.2 Copyright Paul Johnston 2000 - 2009.
     * Other contributors: Greg Holt, Andrew Kepert, Ydnar, Lostinet
     * Distributed under the BSD License
     * See http://pajhome.org.uk/crypt/md5 for details.
     */

    /*
     * Configurable variables. You may need to tweak these to be compatible with
     * the server-side, but the defaults work in most cases.
     */
    var hexcase = 0;  /* hex output format. 0 - lowercase; 1 - uppercase        */
    var b64pad  = ""; /* base-64 pad character. "=" for strict RFC compliance   */

    /*
     * These are the functions youll usually want to call
     * They take string arguments and return either hex or base-64 encoded strings
     */
    function hex_sha1(s)    { return rstr2hex(rstr_sha1(str2rstr_utf8(s))); }
    function b64_sha1(s)    { return rstr2b64(rstr_sha1(str2rstr_utf8(s))); }
    function any_sha1(s, e) { return rstr2any(rstr_sha1(str2rstr_utf8(s)), e); }
    function hex_hmac_sha1(k, d)
      { return rstr2hex(rstr_hmac_sha1(str2rstr_utf8(k), str2rstr_utf8(d))); }
    function b64_hmac_sha1(k, d)
      { return rstr2b64(rstr_hmac_sha1(str2rstr_utf8(k), str2rstr_utf8(d))); }
    function any_hmac_sha1(k, d, e)
      { return rstr2any(rstr_hmac_sha1(str2rstr_utf8(k), str2rstr_utf8(d)), e); }

    /*
     * Perform a simple self-test to see if the VM is working
     */
    function sha1_vm_test()
    {
      return hex_sha1("abc").toLowerCase() == "a9993e364706816aba3e25717850c26c9cd0d89d";
    }

    /*
     * Calculate the SHA1 of a raw string
     */
    function rstr_sha1(s)
    {
      return binb2rstr(binb_sha1(rstr2binb(s), s.length * 8));
    }

    /*
     * Calculate the HMAC-SHA1 of a key and some data (raw strings)
     */
    function rstr_hmac_sha1(key, data)
    {
      var bkey = rstr2binb(key);
      if(bkey.length > 16) bkey = binb_sha1(bkey, key.length * 8);

      var ipad = Array(16), opad = Array(16);
      for(var i = 0; i < 16; i++)
      {
        ipad[i] = bkey[i] ^ 0x36363636;
        opad[i] = bkey[i] ^ 0x5C5C5C5C;
      }

      var hash = binb_sha1(ipad.concat(rstr2binb(data)), 512 + data.length * 8);
      return binb2rstr(binb_sha1(opad.concat(hash), 512 + 160));
    }

    /*
     * Convert a raw string to a hex string
     */
    function rstr2hex(input)
    {
      try { hexcase } catch(e) { hexcase=0; }
      var hex_tab = hexcase ? "0123456789ABCDEF" : "0123456789abcdef";
      var output = "";
      var x;
      for(var i = 0; i < input.length; i++)
      {
        x = input.charCodeAt(i);
        output += hex_tab.charAt((x >>> 4) & 0x0F)
               +  hex_tab.charAt( x        & 0x0F);
      }
      return output;
    }

    /*
     * Convert a raw string to a base-64 string
     */
    function rstr2b64(input)
    {
      try { b64pad } catch(e) { b64pad=""; }
      var tab = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      var output = "";
      var len = input.length;
      for(var i = 0; i < len; i += 3)
      {
        var triplet = (input.charCodeAt(i) << 16)
                    | (i + 1 < len ? input.charCodeAt(i+1) << 8 : 0)
                    | (i + 2 < len ? input.charCodeAt(i+2)      : 0);
        for(var j = 0; j < 4; j++)
        {
          if(i * 8 + j * 6 > input.length * 8) output += b64pad;
          else output += tab.charAt((triplet >>> 6*(3-j)) & 0x3F);
        }
      }
      return output;
    }

    /*
     * Convert a raw string to an arbitrary string encoding
     */
    function rstr2any(input, encoding)
    {
      var divisor = encoding.length;
      var remainders = Array();
      var i, q, x, quotient;

      /* Convert to an array of 16-bit big-endian values, forming the dividend */
      var dividend = Array(Math.ceil(input.length / 2));
      for(i = 0; i < dividend.length; i++)
      {
        dividend[i] = (input.charCodeAt(i * 2) << 8) | input.charCodeAt(i * 2 + 1);
      }

      /*
       * Repeatedly perform a long division. The binary array forms the dividend,
       * the length of the encoding is the divisor. Once computed, the quotient
       * forms the dividend for the next step. We stop when the dividend is zero.
       * All remainders are stored for later use.
       */
      while(dividend.length > 0)
      {
        quotient = Array();
        x = 0;
        for(i = 0; i < dividend.length; i++)
        {
          x = (x << 16) + dividend[i];
          q = Math.floor(x / divisor);
          x -= q * divisor;
          if(quotient.length > 0 || q > 0)
            quotient[quotient.length] = q;
        }
        remainders[remainders.length] = x;
        dividend = quotient;
      }

      /* Convert the remainders to the output string */
      var output = "";
      for(i = remainders.length - 1; i >= 0; i--)
        output += encoding.charAt(remainders[i]);

      /* Append leading zero equivalents */
      var full_length = Math.ceil(input.length * 8 /
                                        (Math.log(encoding.length) / Math.log(2)))
      for(i = output.length; i < full_length; i++)
        output = encoding[0] + output;

      return output;
    }

    /*
     * Encode a string as utf-8.
     * For efficiency, this assumes the input is valid utf-16.
     */
    function str2rstr_utf8(input)
    {
      var output = "";
      var i = -1;
      var x, y;

      while(++i < input.length)
      {
        /* Decode utf-16 surrogate pairs */
        x = input.charCodeAt(i);
        y = i + 1 < input.length ? input.charCodeAt(i + 1) : 0;
        if(0xD800 <= x && x <= 0xDBFF && 0xDC00 <= y && y <= 0xDFFF)
        {
          x = 0x10000 + ((x & 0x03FF) << 10) + (y & 0x03FF);
          i++;
        }

        /* Encode output as utf-8 */
        if(x <= 0x7F)
          output += String.fromCharCode(x);
        else if(x <= 0x7FF)
          output += String.fromCharCode(0xC0 | ((x >>> 6 ) & 0x1F),
                                        0x80 | ( x         & 0x3F));
        else if(x <= 0xFFFF)
          output += String.fromCharCode(0xE0 | ((x >>> 12) & 0x0F),
                                        0x80 | ((x >>> 6 ) & 0x3F),
                                        0x80 | ( x         & 0x3F));
        else if(x <= 0x1FFFFF)
          output += String.fromCharCode(0xF0 | ((x >>> 18) & 0x07),
                                        0x80 | ((x >>> 12) & 0x3F),
                                        0x80 | ((x >>> 6 ) & 0x3F),
                                        0x80 | ( x         & 0x3F));
      }
      return output;
    }

    /*
     * Encode a string as utf-16
     */
    function str2rstr_utf16le(input)
    {
      var output = "";
      for(var i = 0; i < input.length; i++)
        output += String.fromCharCode( input.charCodeAt(i)        & 0xFF,
                                      (input.charCodeAt(i) >>> 8) & 0xFF);
      return output;
    }

    function str2rstr_utf16be(input)
    {
      var output = "";
      for(var i = 0; i < input.length; i++)
        output += String.fromCharCode((input.charCodeAt(i) >>> 8) & 0xFF,
                                       input.charCodeAt(i)        & 0xFF);
      return output;
    }

    /*
     * Convert a raw string to an array of big-endian words
     * Characters >255 have their high-byte silently ignored.
     */
    function rstr2binb(input)
    {
      var output = Array(input.length >> 2);
      for(var i = 0; i < output.length; i++)
        output[i] = 0;
      for(var i = 0; i < input.length * 8; i += 8)
        output[i>>5] |= (input.charCodeAt(i / 8) & 0xFF) << (24 - i % 32);
      return output;
    }

    /*
     * Convert an array of big-endian words to a string
     */
    function binb2rstr(input)
    {
      var output = "";
      for(var i = 0; i < input.length * 32; i += 8)
        output += String.fromCharCode((input[i>>5] >>> (24 - i % 32)) & 0xFF);
      return output;
    }

    /*
     * Calculate the SHA-1 of an array of big-endian words, and a bit length
     */
    function binb_sha1(x, len)
    {
      /* append padding */
      x[len >> 5] |= 0x80 << (24 - len % 32);
      x[((len + 64 >> 9) << 4) + 15] = len;

      var w = Array(80);
      var a =  1732584193;
      var b = -271733879;
      var c = -1732584194;
      var d =  271733878;
      var e = -1009589776;

      for(var i = 0; i < x.length; i += 16)
      {
        var olda = a;
        var oldb = b;
        var oldc = c;
        var oldd = d;
        var olde = e;

        for(var j = 0; j < 80; j++)
        {
          if(j < 16) w[j] = x[i + j];
          else w[j] = bit_rol(w[j-3] ^ w[j-8] ^ w[j-14] ^ w[j-16], 1);
          var t = safe_add(safe_add(bit_rol(a, 5), sha1_ft(j, b, c, d)),
                           safe_add(safe_add(e, w[j]), sha1_kt(j)));
          e = d;
          d = c;
          c = bit_rol(b, 30);
          b = a;
          a = t;
        }

        a = safe_add(a, olda);
        b = safe_add(b, oldb);
        c = safe_add(c, oldc);
        d = safe_add(d, oldd);
        e = safe_add(e, olde);
      }
      return Array(a, b, c, d, e);

    }

    /*
     * Perform the appropriate triplet combination function for the current
     * iteration
     */
    function sha1_ft(t, b, c, d)
    {
      if(t < 20) return (b & c) | ((~b) & d);
      if(t < 40) return b ^ c ^ d;
      if(t < 60) return (b & c) | (b & d) | (c & d);
      return b ^ c ^ d;
    }

    /*
     * Determine the appropriate additive constant for the current iteration
     */
    function sha1_kt(t)
    {
      return (t < 20) ?  1518500249 : (t < 40) ?  1859775393 :
             (t < 60) ? -1894007588 : -899497514;
    }

    /*
     * Add integers, wrapping at 2^32. This uses 16-bit operations internally
     * to work around bugs in some JS interpreters.
     */
    function safe_add(x, y)
    {
      var lsw = (x & 0xFFFF) + (y & 0xFFFF);
      var msw = (x >> 16) + (y >> 16) + (lsw >> 16);
      return (msw << 16) | (lsw & 0xFFFF);
    }

    /*
     * Bitwise rotate a 32-bit number to the left.
     */
    function bit_rol(num, cnt)
    {
      return (num << cnt) | (num >>> (32 - cnt));
    }

    function PBKDF2(a, b, c, d) {
        var e, f, g = rstr2binb(a),
            h = b,
            i = c,
            j = 10,
            k = 0,
            l = d,
            m = null,
            n = 20,
            o = Math.ceil(l / n),
            p = 1,
            q = new Array(16),
            r = new Array(16),
            s = new Array(0, 0, 0, 0, 0),
            t = "",
            u = this;
        g.length > 16 && (g = binb_sha1(g, a.length * chrsz));
        for (var v = 0; 16 > v; ++v) q[v] = 909522486 ^ g[v], r[v] = 1549556828 ^ g[v];
        this.deriveKey = function (a, b) {
            f = a; e = b; u.do_PBKDF2_iterations();
        }, this.do_PBKDF2_iterations = function () {
            var a = j;
            j > i - k && (a = i - k);
            for (var b = 0; a > b; ++b) {
                if (0 == k) {
                    var c = h + String.fromCharCode(p >> 24 & 15) + String.fromCharCode(p >> 16 & 15) + String.fromCharCode(p >> 8 & 15) + String.fromCharCode(15 & p);
                    m = binb_sha1(q.concat(rstr2binb(c)), 512 + 8 * c.length), m = binb_sha1(r.concat(m), 672)
                } else m = binb_sha1(q.concat(m), 512 + 32 * m.length), m = binb_sha1(r.concat(m), 672);
                for (var d = 0; d < m.length; ++d) s[d] ^= m[d];
                k++
            }
            if (f((p - 1 + k / i) / o * 100), i > k)
                u.do_PBKDF2_iterations();
            else if (o > p)
            {
             t += rstr2hex(binb2rstr(s)); p++; s = new Array(0, 0, 0, 0, 0); k = 0;
                u.do_PBKDF2_iterations();
            }
            else {
                var g = rstr2hex(binb2rstr(s));
                t += g.substr(0, 2 * (l - (o - 1) * n)), e(t)
            }
        }
    }
    '

    split_auth "$AUTH" USER PASSWORD || return

    JS="var password='$PASSWORD'; var pbk = new PBKDF2(password, String(password).split(\"\").reverse().join(\"\"), 1e3, 16); pbk.deriveKey(function(){}, function(pbk_res){print(pbk_res)});"
    PASS_PBKDF2=$(javascript <<< "$PBKDF2_SCRIPT$JS")

    PAGE=$(curl \
        -d "auth=$USER" \
        -d "pass=$PASS_PBKDF2" \
        'https://www.oboom.com/1/login') || return

    oboom_check_error "$PAGE" 'Login' || return

    ACC_SESSION=$(parse_json 'session' <<< "$PAGE") || return
    ACC_PREMIUM=$(parse_json 'premium' <<< "$PAGE") || return

    echo "$ACC_SESSION"
    echo "$ACC_PREMIUM"
}

oboom_check_error() {
    local -r PAGE=$1
    local -r OPERATION=$2

    local ERR_CODE ERR_MSG

    if ! match '^\[200' "$PAGE"; then
        ERR_CODE=$(parse_quiet . '^\[\([0-9]\+\)' <<< "$PAGE")
        ERR_MSG=$(parse_quiet . '^\[[0-9]\+,"\([^"]\+\)' <<< "$PAGE")

        if [ "$ERR_CODE" = '400' ]; then
            [ "$ERR_MSG" = 'Invalid Login Credentials' ] && return $ERR_LOGIN_FAILED
            [ "$ERR_MSG" = 'incorrect-captcha-sol' ] && return $ERR_CAPTCHA

        # [403,"filesize",1572864000,1073741824]
        elif [ "$ERR_CODE" = '403' ]; then
            [ "$ERR_MSG" = 'blocked' ] && return $ERR_LINK_DEAD

            local -r MAX_SIZE=${PAGE##*,}
            log_debug "limitation is set to ${MAX_SIZE%]} bytes"
            return $ERR_SIZE_LIMIT_EXCEEDED

        elif [ "$ERR_CODE" = '404' ] || [ "$ERR_CODE" = '410' ]; then
            return $ERR_LINK_DEAD
        elif [ "$ERR_CODE" = '421' ]; then
            if [ "$ERR_MSG" = 'ip_blocked' ]; then
                WAIT_TIME=$(parse . '^\[421,"ip_blocked",\([0-9]\+\)\]$' <<< "$PAGE")

                echo "$WAIT_TIME"
                return $ERR_LINK_TEMP_UNAVAILABLE
            fi
        fi

        if [ -z "$ERR_CODE" ]; then
            log_error "$OPERATION failed. Unknown error."
        else
            log_error "$OPERATION failed. Remote error ($ERR_CODE): '$ERR_MSG'."
        fi
    fi
}

# Output a oboom.com file download URL and name
# $1: cookie file (not used here)
# $2: oboom.com url
# stdout: file download link
#         file name
oboom_download() {
    #local -r COOKIE_FILE=$1
    local -r URL=$2

    local PAGE FILE_ID USER_ID ERROR FILE_NAME FILE_URL LOGIN_DATA ACC_SESSION DOWNLOAD_AUTH DOWNLOAD_DOMAIN DOWNLOAD_TICKET

    FILE_ID=$(parse . 'oboom.com/#\?\([^/]\+\)' <<< "$URL") || return

    if [ -n "$AUTH" ]; then
        LOGIN_DATA=$(oboom_login "$AUTH") || return
        { read -r ACC_SESSION; read -r ACC_PREMIUM; } <<< "$LOGIN_DATA"
    else
        PAGE=$(curl \
            'http://www.oboom.com/1/guestsession') || return

        oboom_check_error "$PAGE" 'Guest session init' || return

        ACC_SESSION=$(parse . '^\[200,"\([^"]\+\)' <<< "$PAGE") || return
    fi

    log_debug "Session ID: $ACC_SESSION (premium: $ACC_PREMIUM)"

    PAGE=$(curl \
        -d "token=$ACC_SESSION" \
        -d "item=$FILE_ID" \
        'http://api.oboom.com/1/ls') || return

    oboom_check_error "$PAGE" 'Pre-download check' || return

    FILE_NAME=$(parse_json 'name' <<< "$PAGE") || return
    # In case of unicode names \u1234
    FILE_NAME=$(echo -e "$FILE_NAME")
    # If user ID present then it is user's file and can be downloaded as premium even on free account
    USER_ID=$(parse_json_quiet 'user' <<< "$PAGE") || return

    if [ -z "$AUTH" ] || [ "$ACC_PREMIUM" = 'null' -a -z "$USER_ID" ]; then
        local PUBKEY='6LdqpO0SAAAAAJGHXo63HyalP7H4qlRs_vff0kJX'
        local WCI CHALLENGE WORD ID

        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

        PAGE=$(curl \
            -d "recaptcha_challenge_field=$CHALLENGE" \
            -d "recaptcha_response_field=$WORD" \
            -d "download_id=$FILE_ID" \
            -d "token=$ACC_SESSION" \
            'http://www.oboom.com/1/dl/ticket') || return

        if match '^\[403,[0-9]\+\]$' "$PAGE"; then
            WAIT_TIME=$(parse . '^\[403,\([0-9]\+\)' <<< "$PAGE") || return

            echo "$WAIT_TIME"
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        oboom_check_error "$PAGE" 'Download auth' || ERROR=$?

        if [ "$ERROR" = $ERR_CAPTCHA ]; then
            log_error 'Wrong captcha.'
            captcha_nack $ID
        fi

        captcha_ack $ID

        [ -n "$ERROR" ] && return $ERROR

        ACC_SESSION=$(parse . '^\[200,"\([^"]\+\)' <<< "$PAGE") || return
        DOWNLOAD_AUTH=$(parse . '^\[200,"[^"]*","\([^"]\+\)' <<< "$PAGE") || return
        DOWNLOAD_AUTH="-d auth=$DOWNLOAD_AUTH"
    else
        MODULE_OBOOM_DOWNLOAD_RESUME=yes
    fi

    PAGE=$(curl \
        -d "token=$ACC_SESSION" \
        -d "item=$FILE_ID" \
        $DOWNLOAD_AUTH \
        'http://api.oboom.com/1/dl') || return

    oboom_check_error "$PAGE" 'Download init' || return

    DOWNLOAD_DOMAIN=$(parse . '^\[200,"\([^"]\+\)' <<< "$PAGE") || return
    DOWNLOAD_TICKET=$(parse . '^\[200,"[^"]*","\([^"]\+\)' <<< "$PAGE") || return

    FILE_URL="http://$DOWNLOAD_DOMAIN/1/dlh?ticket=$DOWNLOAD_TICKET"

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to oboom.com
# $1: cookie file (not used here)
# $2: file path or remote url
# $3: remote filename
# stdout: download link
oboom_upload() {
    #local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://www.oboom.com'

    local FOLDER_ID=1
    local PAGE FOLDERS FOLDERS_N FILE_ID FILE_NAME

    [ -n "$AUTH" ] || return $ERR_LINK_NEED_PERMISSIONS

    if [ -n "$AUTH" ]; then
        LOGIN_DATA=$(oboom_login "$AUTH") || return
        read -r ACC_SESSION <<< "$LOGIN_DATA"
    fi

    log_debug "Session ID: $ACC_SESSION"

    if [ -n "$FOLDER" ]; then
        PAGE=$(curl \
            -d "token=$ACC_SESSION" \
            'http://api.oboom.com/1/tree') || return

        FOLDER_ID=$(parse_quiet . \
            "\"name\":\"$FOLDER\"[^\}]\+\"type\":\"folder\"[^\}]\+\"id\":\"\([^\"]\+\)\"" <<< "$PAGE")

        if [ -z "$FOLDER_ID" ]; then
            log_debug 'Creating folder...'

            PAGE=$(curl \
                -d "token=$ACC_SESSION" \
                -d 'parent=1' \
                -d "name=$FOLDER" \
                -d 'name_policy=fail' \
                'http://api.oboom.com/1/mkdir') || return

            if match '^\[200\]$' "$PAGE"; then
                log_debug 'Folder created.'
            elif match '\[409,"item with same name already exists"' "$PAGE"; then
                log_debug 'Folder already exists.'
            elif ! match '^\[200\]$' "$PAGE"; then
                log_error 'Failed to create folder.'
                return $ERR_FATAL
            fi

            PAGE=$(curl \
                -d "token=$ACC_SESSION" \
                'http://api.oboom.com/1/tree') || return

            FOLDER_ID=$(parse . \
                "\"name\":\"$FOLDER\"[^\}]\+\"type\":\"folder\"[^\}]\+\"id\":\"\([^\"]\+\)\"" <<< "$PAGE") || return
        fi

        log_debug "Folder ID: '$FOLDER_ID'"
    fi

    # Upload remote file
    if match_remote_url "$FILE"; then
        local UPLOAD_ID UPLOAD_STATE UPLOAD_ERROR

        if ! match '^https\?://' "$FILE" && ! match '^ftp://' "$FILE"; then
            log_error 'Unsupported protocol for remote upload.'
            return $ERR_BAD_COMMAND_LINE
        fi

        PAGE=$(curl \
            -d "token=$ACC_SESSION" \
            -d "remotes=[{\"url\":\"$FILE\",\"parent\":\"$FOLDER_ID\",\"name_policy\":\"rename\"}]" \
            "http://api.oboom.com/1/remote/add") || return

        oboom_check_error "$PAGE" 'Remote upload' || return

        UPLOAD_ID=$(parse_json 'id' <<< "$PAGE")

        log_debug "Upload ID: $UPLOAD_ID"

        if [ -n "$ASYNC" ]; then
            log_error 'Once remote upload completed, check your account for link.'
            return $ERR_ASYNC_REQUEST
        fi

        local TRY=1
        while [ "$UPLOAD_STATE" != 'complete' ]; do
            PAGE=$(curl \
                -d "token=$ACC_SESSION" \
                'http://api.oboom.com/1/remote/lsall') || return

            PAGE=$(replace_all '{', $'\n{' <<< "$PAGE") || return
            PAGE=$(replace_all '}', $'}\n' <<< "$PAGE") || return

            UPLOAD_STATE=$(parse "\"id\":$UPLOAD_ID" '"state":"\([^"]\+\)' <<< "$PAGE") || return

            [ "$UPLOAD_STATE" = 'complete' ] && break

            if [ "$UPLOAD_STATE" != 'pending' ] && [ "$UPLOAD_STATE" != 'working' ]; then
                if [ "$UPLOAD_STATE" = 'failed' ]; then
                    UPLOAD_ERROR=$(parse "\"id\":$FILE_ID" '"last_error":"\?\([^",]\+\)' <<< "$PAGE") || return
                    log_error "Upload failed. Remote error: '$UPLOAD_ERROR'."
                else
                    log_error "Upload failed. Unknown state: '$FILE_STATE'."
                fi
                return $ERR_FATAL
            fi

            log_debug "Wait for server to download the file... [$((TRY++))]"
            wait 15 || return
        done

        FILE_ID=$(parse "\"id\":$UPLOAD_ID" '"item":"\([^"]\+\)' <<< "$PAGE") || return
        FILE_NAME=$(parse "\"id\":$UPLOAD_ID" '"name":"\([^"]\+\)' <<< "$PAGE") || return

        # Do we need to rename the file?
        if [ "$DEST_FILE" != 'dummy' ]; then
            local ERROR

            log_debug 'Renaming file...'

            PAGE=$(curl \
                -d "token=$ACC_SESSION" \
                -d "items=$FILE_ID" \
                -d "target=$FOLDER_ID" \
                -d "new_name=$DEST_FILE" \
                -d 'name_policy=rename' \
                'http://api.oboom.com/1/mv') || return

            oboom_check_error "$PAGE" 'Rename' || ERROR=$?

            if [ -z "$ERROR" ]; then
                PAGE=$(curl \
                    -d "token=$ACC_SESSION" \
                    -d "item=$FILE_ID" \
                    'http://api.oboom.com/1/ls') || return

                FILE_NAME=$(parse_json 'name' <<< "$PAGE") || return
            fi
        fi

    # Upload local file
    else
        PAGE=$(curl_with_log \
            -F "file=@$FILE;filename=$DESTFILE" \
            "http://upload.oboom.com/1/ul?token=$ACC_SESSION&parent=$FOLDER_ID") || return

        oboom_check_error "$PAGE" 'Upload' || return

        FILE_ID=$(parse_json 'id' <<< "$PAGE") || return
        FILE_NAME=$(parse_json 'name' <<< "$PAGE") || return
    fi

    # In case of unicode names \u1234
    FILE_NAME=$(echo -e "$FILE_NAME")

    echo "http://www.oboom.com/$FILE_ID/$FILE_NAME"
}

# List a oboom.com web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
oboom_list() {
    local -r URL=$1
    local -r REC=$2
    local PAGE FILE_ID FILE_ID_C FILE_ID_LIST LINKS NAMES

    FILE_ID=$(parse . 'oboom.com/#\?folder/\([^/]\+\)' <<< "$URL") || return

    PAGE=$(curl \
        -d "item=$FILE_ID" \
        'http://api.oboom.com/1/ls') || return

    oboom_check_error "$PAGE" 'List' || return

    PAGE=$(replace_all '{', $'\n{' <<< "$PAGE") || return
    PAGE=$(replace_all '}', $'}\n' <<< "$PAGE") || return

    FILE_ID_LIST=$(parse_all_quiet '"type":"file"' '"id":"\([^"]\+\)' <<< "$PAGE")
    while read FILE_ID_C; do
        [ -z "$FILE_ID_C" ] && continue

        if [ -z "$LINKS" ]; then
            LINKS="http://www.oboom.com/$FILE_ID_C"
        else
            LINKS=$LINKS$'\n'"http://www.oboom.com/$FILE_ID_C"
        fi
    done <<< "$FILE_ID_LIST"

    NAMES=$(parse_all_quiet '"type":"file"' '"name":"\([^"]\+\)' <<< "$PAGE")
    # In case of unicode names \u1234
    NAMES=$(echo -e "$NAMES")

    list_submit "$LINKS" "$NAMES"

    if [ -n "$REC" ]; then
        local FOLDERS FOLDER_ID

        FOLDERS=$(parse_all_quiet '"type":"folder"' '"id":"\([^"]\+\)' <<< "$PAGE")
        # First folder is always self link
        FOLDERS=$(delete_first_line <<< "$FOLDERS")

        while read FOLDER_ID; do
            [ -z "$FOLDER_ID" ] && continue
            log_debug "Entering sub folder: $FOLDER_ID"
            oboom_list "http://www.oboom.com/folder/$FOLDER_ID" "$REC" && RET=0
        done <<< "$FOLDERS"
    fi
}

# Probe a download URL
# $1: cookie file (not used here)
# $2: oboom.com url
# $3: requested capability list
# stdout: 1 capability per line
oboom_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_ID FILE_NAME FILE_SIZE REQ_OUT

    FILE_ID=$(parse . 'oboom.com/#\?\([^/]\+\)' <<< "$URL") || return

    PAGE=$(curl \
        -d "item=$FILE_ID" \
        'http://api.oboom.com/1/ls') || return

    oboom_check_error "$PAGE" 'Probe' || return

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_json 'name' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_json 'size' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
