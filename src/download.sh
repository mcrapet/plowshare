#!/usr/bin/env bash
#
# Download files from file sharing websites
# Copyright (c) 2010-2016 Plowshare team
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

declare -r VERSION='GIT-snapshot'

declare -r EARLY_OPTIONS="
HELP,h,help,,Show help info and exit
HELPFUL,H,longhelp,,Exhaustive help info (with modules command-line options)
GETVERSION,,version,,Output plowdown version information and exit
ALLMODULES,,modules,,Output available modules (one per line) and exit. Useful for wrappers.
EXT_PLOWSHARERC,,plowsharerc,f=FILE,Force using an alternate configuration file (overrides default search path)
NO_PLOWSHARERC,,no-plowsharerc,,Do not use any plowshare.conf configuration file"

declare -r MAIN_OPTIONS="
VERBOSE,v,verbose,c|0|1|2|3|4=LEVEL,Verbosity level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
MARK_DOWN,m,mark-downloaded,,Mark downloaded links (useful for file list arguments)
NOOVERWRITE,x,no-overwrite,,Do not overwrite existing files
OUTPUT_DIR,o,output-directory,D=DIR,Directory where files will be saved
TEMP_DIR,,temp-directory,D=DIR,Directory for temporary files (final link download, cookies, images)
TEMP_RENAME,,temp-rename,,Append .part suffix to filename while file is being downloaded
MAX_LIMIT_RATE,,max-rate,r=SPEED,Limit maximum speed to bytes/sec (accept usual suffixes)
MIN_LIMIT_SPACE,,min-space,R=LIMIT,Set the minimum amount of disk space to exit.
INTERFACE,i,interface,s=IFACE,Force IFACE network interface
TIMEOUT,t,timeout,n=SECS,Timeout after SECS seconds of waits
MAXRETRIES,r,max-retries,N=NUM,Set maximum retries for download failures (captcha, network errors). Default is 2 (3 tries).
CACHE,,cache,C|none|session|shared=METHOD,Policy for storage data. Available: none, session (default), shared.
CAPTCHA_METHOD,,captchamethod,s=METHOD,Force specific captcha solving method. Available: online, imgur, x11, fb, nox, none.
CAPTCHA_PROGRAM,,captchaprogram,F=PROGRAM,Call external program/script for captcha solving.
CAPTCHA_9KWEU,,9kweu,s=KEY,9kw.eu captcha (API) key
CAPTCHA_ANTIGATE,,antigate,s=KEY,Antigate.com captcha key
CAPTCHA_BHOOD,,captchabhood,a=USER:PASSWD,CaptchaBrotherhood account
CAPTCHA_COIN,,captchacoin,s=KEY,captchacoin.com API key
CAPTCHA_DEATHBY,,deathbycaptcha,a=USER:PASSWD,DeathByCaptcha account
PRE_COMMAND,,run-before,F=PROGRAM,Call external program/script before new link processing
POST_COMMAND,,run-after,F=PROGRAM,Call external program/script after link being successfully processed
SKIP_FINAL,,skip-final,,Don't process final link (returned by module), just skip it (for each link)
PRINTF_FORMAT,,printf,s=FORMAT,Print results in a given format (for each successful download). Default is \"%F%n\".
NO_COLOR,,no-color,,Disables log notice & log error output coloring
NO_MODULE_FALLBACK,,fallback,,If no module is found for link, simply download it (HTTP GET)
EXT_CURLRC,,curlrc,f=FILE,Force using an alternate curl configuration file (overrides ~/.curlrc)
NO_CURLRC,,no-curlrc,,Do not use curlrc config file"


# Translate to absolute path (like GNU "readlink -f")
# $1: script path (usually a symlink)
# Note: If '-P' flags (of cd) are removed, directory symlinks
# won't be translated (but results are correct too).
absolute_path() {
    local SAVED_PWD=$PWD
    local TARGET=$1

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
    done

    if [ -f "$TARGET" ]; then
        DIR=$(dirname "$TARGET")
    else
        DIR=$TARGET
    fi

    cd -P "$DIR"
    TARGET=$PWD
    cd "$SAVED_PWD"
    echo "$TARGET"
}

# Guess if item is a generic URL (a simple link string) or a text file with links.
# $1: single URL or file (containing links)
process_item() {
    local -r ITEM=$1

    if match_remote_url "$ITEM" ftp ftps; then
        echo 'url'
        strip <<< "$ITEM"
    elif [ -f "$ITEM" ]; then
        local MATCH

        if check_exec 'file'; then
            [[ $(file -i "$ITEM") =~ \ charset=binary$ ]] && MATCH=1
        else
            [[ $ITEM =~ \.(zip|rar|tar|[7gx]z|bz2|mp[234g]|avi|mkv|jpg)$ ]] && MATCH=1
        fi

        if [ -z "$MATCH" ]; then
            # Discard empty lines and comments
            echo 'file'
            sed -ne '/^[[:space:]]*[^#[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p}' "$ITEM"
        else
            log_error "Skip: '$ITEM' seems to be a binary file, not a list of links"
        fi
    else
        log_error "Skip: cannot stat '$ITEM': No such file or directory"
    fi
}

# Print usage (on stdout)
# Note: Global array variable MODULES is accessed directly.
usage() {
    echo 'Usage: plowdown [OPTIONS] [MODULE_OPTIONS] URL|FILE...'
    echo 'Download files from file sharing websites.'
    echo
    echo 'Global options:'
    print_options "$EARLY_OPTIONS$MAIN_OPTIONS"
    test -z "$1" || print_module_options MODULES[@] DOWNLOAD
}

# Mark status of link (inside file or to stdout). See --mark-downloaded switch.
# $1: type ("file" or "url" string)
# $2: mark link (boolean) flag
# $3: if type="file": list file (containing URLs)
# $4: raw URL
# $5: status string (OK, PASSWORD, NOPERM, NOTFOUND, NOMODULE)
# $6: filename (can be non empty if not available)
mark_queue() {
    local -r FILE=$3
    local -r URL=$4
    local -r STATUS="#$5"
    local FILENAME=${6:+"# $6"}

    if [ -n "$2" ]; then
        if [ 'file' = "$1" ]; then
            if test -w "$FILE"; then
                local -r D=$'\001' # sed separator
                test "$FILENAME" && FILENAME="${FILENAME//&/\\&}\n"
                sed -i -e "s$D^[[:space:]]*\(${URL//\\/\\\\/}[[:space:]]*\)\$$D$FILENAME$STATUS \1$D" "$FILE" &&
                    log_notice "link marked in file \`$FILE' ($STATUS)" ||
                    log_error "failed marking link in file \`$FILE' ($STATUS)"
            else
                log_error "Can't mark link, no write permission ($FILE)"
            fi
        else
            test "$FILENAME" && echo "$FILENAME"
            echo "$STATUS $URL"
        fi
    fi
}

# Create an alternative filename
# Pattern is filename.1
#
# $1: filename (with or without path)
# stdout: non existing filename
create_alt_filename() {
    local -r FILENAME=$1
    local -i COUNT=0

    while (( ++COUNT < 100 )); do
        [ -f "$FILENAME.$COUNT" ] || break
    done
    echo "$FILENAME.$COUNT"
}

# Find mount point which belongs to given directory
# $1: directory
# $?: 0 for success
# stdout: mount point (for example: /media/usbkey)
disk_mount_point() {
    local MOUNT DIR
    local -a F

    while read -r -a F; do
        MOUNT=${F[5]}
        # Mount point should be a substring of $1
        if [[ $1 = ${MOUNT}* ]]; then
            [[ $DIR > $MOUNT ]] || DIR=$MOUNT
        fi
    done < <(df -P -k|sed -ne '2,$p')

    [ -z "$DIR" ] && return $ERR_FATAL
    echo "$DIR"
}

# Check filesystem disk space
# $1: mount point returned by disk_mount_point()
# $2: limit (in bytes)
# $?: 0 when free disk space is strictly below requested size
disk_check() {
    local -a F
    local -ir KB_SIZE=$(($2 / 1024))

    read -r -a F < <(df -P -k | grep "$1\$" | head -n1)
    if [[ ${F[3]} -lt $KB_SIZE ]]; then
        log_error "Requested disk limit reached. Available space on $1 is ${F[3]} bytes. Aborting."
        return $ERR_SYSTEM
    fi
}

# Example: "MODULE_RYUSHARE_DOWNLOAD_RESUME=no"
# $1: module name
module_config_resume() {
    local -u VAR="MODULE_${1}_DOWNLOAD_RESUME"
    [[ ${!VAR} = [Yy][Ee][Ss] || ${!VAR} = 1 ]]
}

# Example: "MODULE_RYUSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no"
# $1: module name
module_config_need_cookie() {
    local -u VAR="MODULE_${1}_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE"
    [[ ${!VAR} = [Yy][Ee][Ss] || ${!VAR} = 1 ]]
}

# Example: "MODULE_RYUSHARE_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=(-F "key=value")
# $1: module name
# stdout: variable array name (not content)
# $?: 0 for success (non empty array)
module_config_need_extra() {
    local -u VAR="MODULE_${1}_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA"
    test -n "${!VAR}" && echo "${VAR}[@]"
}

# Example: "MODULE_RYUSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=10"
# $1: module name
module_config_wait() {
    local -u VAR="MODULE_${1}_DOWNLOAD_SUCCESSIVE_INTERVAL"
    echo $((${!VAR}))
}

# Fake download module function. See --fallback switch.
# $1: cookie file (unused here)
# $2: unknown url
# stdout: $2
module_null_download() {
    echo "$2"
}

# Note: Global options $INDEX, $MARK_DOWN, $NOOVERWRITE,
# $TIMEOUT, $CAPTCHA_METHOD, $PRINTF_FORMAT, $SKIP_FINAL,
# $PRE_COMMAND, $POST_COMMAND, $TEMP_DIR, $TEMP_RENAME are accessed directly.
download() {
    local -r MODULE=$1
    local -r URL_RAW=$2
    local -r TYPE=$3
    local -r ITEM=$4
    local -r OUT_DIR=$5
    local -r MAX_RETRIES=$6
    local -r LAST_HOST=$7

    local DRETVAL DRESULT AWAIT FILE_NAME FILE_URL COOKIE_FILE COOKIE_JAR ANAME BASE_URL
    local -i STATUS FILE_SIZE
    local URL_ENCODED=$(uri_encode <<< "$URL_RAW")
    local FUNCTION=${MODULE}_download

    log_notice "Starting download ($MODULE): $URL_ENCODED"
    timeout_init $TIMEOUT

    AWAIT=$(module_config_wait "$MODULE")
    if [[ $AWAIT -gt 0 && $URL = $LAST_HOST* && -z "$SKIP_FINAL" ]]; then
        log_notice 'Same previous hoster, forced wait requested'
        wait $AWAIT || {
            log_error "Delay limit reached (${FUNCTION})";
            return $ERR_MAX_WAIT_REACHED;
        }
    fi

    while :; do
        COOKIE_FILE=$(create_tempfile)

        # Pre-processing script (executed in a subshell)
        if [ -n "$PRE_COMMAND" ]; then
            DRETVAL=0
            (exec "$PRE_COMMAND" "$MODULE" "$URL_ENCODED" "$COOKIE_FILE") >/dev/null || DRETVAL=$?

            if [ $DRETVAL -eq $ERR_NOMODULE ]; then
                log_notice "Skipping link (as requested): $URL_ENCODED"
                rm -f "$COOKIE_FILE"
                return $ERR_NOMODULE
            elif [ $DRETVAL -ne 0 ]; then
                log_error "Pre-processing script exited with status $DRETVAL, continue anyway"
            fi
        fi

        local -i TRY=0
        DRESULT=$(create_tempfile) || return

        while :; do
            DRETVAL=0
            $FUNCTION "$COOKIE_FILE" "$URL_ENCODED" >"$DRESULT" || DRETVAL=$?

            # $ERR_LINK_TEMP_UNAVAILABLE and $ERR_EXPIRED_SESSION
            # do not count as a retry
            if [ $DRETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
                read AWAIT <"$DRESULT"
                if [ -z "$AWAIT" ]; then
                    log_debug 'arbitrary wait'
                else
                    log_debug 'arbitrary wait (from module)'
                fi
                wait ${AWAIT:-60} || { DRETVAL=$?; break; }
                continue
            elif [ $DRETVAL -eq $ERR_EXPIRED_SESSION ]; then
                log_notice 'expired session: delete cache entry'
                continue
            elif [[ $MAX_RETRIES -eq 0 ]]; then
                break
            elif [ $DRETVAL -ne $ERR_NETWORK -a \
                   $DRETVAL -ne $ERR_CAPTCHA ]; then
                break
            # Special case
            elif [ $DRETVAL -eq $ERR_CAPTCHA -a \
                    "$CAPTCHA_METHOD" = 'none' ]; then
                log_debug 'captcha method set to none, abort'
                break
            elif (( MAX_RETRIES < ++TRY )); then
                DRETVAL=$ERR_MAX_TRIES_REACHED
                break
            fi

            log_notice "Starting download ($MODULE): retry $TRY/$MAX_RETRIES"
        done

        if [ $DRETVAL -eq 0 ]; then
            { read FILE_URL; read FILE_NAME; } <"$DRESULT" || true
        fi

        # Important: keep cookies in a variable and not in a file
        COOKIE_JAR=$(cat "$COOKIE_FILE")
        rm -f "$DRESULT" "$COOKIE_FILE"

        case $DRETVAL in
            0)
                ;;
            $ERR_LOGIN_FAILED)
                log_error 'Login process failed. Bad username/password or unexpected content'
                return $DRETVAL
                ;;
            $ERR_LINK_TEMP_UNAVAILABLE)
                log_error 'File link is alive but not currently available, try later'
                return $DRETVAL
                ;;
            $ERR_LINK_PASSWORD_REQUIRED)
                log_error 'You must provide a valid password'
                mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" PASSWORD
                return $DRETVAL
                ;;
            $ERR_LINK_NEED_PERMISSIONS)
                log_error 'Insufficient permissions (private/premium link)'
                mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" NOPERM
                return $DRETVAL
                ;;
            $ERR_SIZE_LIMIT_EXCEEDED)
                log_error 'Insufficient permissions (file size limit exceeded)'
                return $DRETVAL
                ;;
            $ERR_LINK_DEAD)
                log_error 'Link is not alive: file not found'
                mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" NOTFOUND
                return $DRETVAL
                ;;
            $ERR_MAX_WAIT_REACHED)
                log_error "Delay limit reached (${FUNCTION})"
                return $DRETVAL
                ;;
            $ERR_MAX_TRIES_REACHED)
                log_error "Retry limit reached (max=$MAX_RETRIES)"
                return $DRETVAL
                ;;
            $ERR_CAPTCHA)
                log_error "Error decoding captcha (${FUNCTION})"
                return $DRETVAL
                ;;
            $ERR_SYSTEM)
                log_error "System failure (${FUNCTION})"
                return $DRETVAL
                ;;
            $ERR_BAD_COMMAND_LINE)
                log_error 'Wrong module option, check your command line'
                return $DRETVAL
                ;;
            *)
                log_error "Failed inside ${FUNCTION}() [$DRETVAL]"
                return $ERR_FATAL
                ;;
        esac

        # Sanity check
        if test -z "$FILE_URL"; then
            log_error 'Output URL expected'
            return $ERR_FATAL
        fi

        # Sanity check 2 (no relative url)
        if [[ $FILE_URL = /* ]]; then
            log_error "Output URL is not valid: $FILE_URL"
            return $ERR_FATAL
        fi

        # Sanity check 3
        if [ "$FILE_URL" = "$FILE_NAME" ]; then
            log_error 'Output filename is wrong, check module download function'
            FILE_NAME=""
        fi

        # Sanity check 4
        BASE_URL=$(basename_url "$FILE_URL")
        if [ "$FILE_URL" = "$BASE_URL" ]; then
            log_error "Output URL is not valid: $FILE_URL"
            return $ERR_FATAL
        fi

        if [[ $BASE_URL =~ :([[:digit:]]{2,5})$ ]]; then
            local -i PORT=${BASH_REMATCH[1]}
            if (( PORT != 80 && PORT != 443 )); then
                log_notice "WARNING: Final URL requires an outgoing TCP connection to port $PORT, hope you're not behind a proxy/firewall."
            fi
        fi

        if test -z "$FILE_NAME"; then
            if [[ $FILE_URL = */ ]]; then
                log_notice 'Output filename not specified, module download function might be wrong'
                FILE_NAME="dummy-$$"
            else
                FILE_NAME=$(basename_file "${FILE_URL%%\?*}" | tr -d '\r\n' | \
                    html_to_utf8 | uri_decode)
            fi
        fi

        # Sanity check 5
        if [[ $FILE_NAME =~ $'\r' ]]; then
            log_debug 'filename contains \r, remove it'
            FILE_NAME=${FILE_NAME//$'\r'}
        fi

        # On most filesystems, maximum filename length is 255
        # http://en.wikipedia.org/wiki/Comparison_of_file_systems
        if [ "${#FILE_NAME}" -ge 255 ]; then
            FILE_NAME="${FILE_NAME:0:254}"
            log_debug 'filename is too long, truncating it'
        fi

        # Sanity check 6
        if [[ $FILE_NAME =~ / ]]; then
            log_debug 'filename contains slashes, translate to underscore'
            FILE_NAME=${FILE_NAME//\//_}
        fi

        FILE_URL=$(uri_encode <<< "$FILE_URL")

        log_notice "File URL: $FILE_URL"
        log_notice "Filename: $FILE_NAME"

        # Process "final download link" here
        if [ -z "$SKIP_FINAL" ]; then
            local FILENAME_TMP FILENAME_OUT
            local -a CURL_ARGS=()

            # Temporary download filename (with full path)
            if test "$TEMP_DIR"; then
                FILENAME_TMP="$TMPDIR/$FILE_NAME"
            elif test "$OUT_DIR"; then
                FILENAME_TMP="$OUT_DIR/$FILE_NAME"
            else
                FILENAME_TMP=$FILE_NAME
            fi

            # Final filename (with full path)
            if test "$OUT_DIR"; then
                FILENAME_OUT="$OUT_DIR/$FILE_NAME"
            else
                FILENAME_OUT=$FILE_NAME
            fi

            if [ -n "$NOOVERWRITE" -a -f "$FILENAME_OUT" ]; then
                if [ "$FILENAME_OUT" = "$FILENAME_TMP" ]; then
                    FILENAME_OUT=$(create_alt_filename "$FILENAME_OUT")
                    FILENAME_TMP=$FILENAME_OUT
                else
                    FILENAME_OUT=$(create_alt_filename "$FILENAME_OUT")
                fi
                FILE_NAME=$(basename_file "$FILENAME_OUT")
            fi

            if test "$TEMP_RENAME"; then
                FILENAME_TMP+='.part'
            fi

            if [ "$FILENAME_OUT" = "$FILENAME_TMP" ]; then
                if [ -f "$FILENAME_OUT" ]; then
                    # Can we overwrite destination file?
                    if [ ! -w "$FILENAME_OUT" ]; then
                        if module_config_resume "$MODULE"; then
                            log_error "ERROR: No write permission, cannot resume final file ($FILENAME_OUT)"
                        else
                            log_error "ERROR: No write permission, cannot overwrite final file ($FILENAME_OUT)"
                        fi
                        return $ERR_SYSTEM
                    fi

                    if [ -s "$FILENAME_OUT" ]; then
                        module_config_resume "$MODULE" && \
                            CURL_ARGS=("${CURL_ARGS[@]}" -C -)
                    fi
                fi
            else
                if [ -f "$FILENAME_OUT" ]; then
                    # Can we overwrite destination file?
                    if [ ! -w "$FILENAME_OUT" ]; then
                        log_error "ERROR: No write permission, cannot overwrite final file ($FILENAME_OUT)"
                        return $ERR_SYSTEM
                    fi
                    log_notice 'WARNING: The filename file already exists, overwrite it. Use `plowdown --no-overwrite'\'' to disable.'
                fi

                if [ -f "$FILENAME_TMP" ]; then
                    # Can we overwrite temporary file?
                    if [ ! -w "$FILENAME_TMP" ]; then
                        if module_config_resume "$MODULE"; then
                            log_error "ERROR: No write permission, cannot resume tmp/part file ($FILENAME_TMP)"
                        else
                            log_error "ERROR: No write permission, cannot overwrite tmp/part file ($FILENAME_TMP)"
                        fi
                        return $ERR_SYSTEM
                    fi

                    if [ -s "$FILENAME_TMP" ] ; then
                        module_config_resume "$MODULE" && \
                            CURL_ARGS=("${CURL_ARGS[@]}" -C -)
                    fi
                fi
            fi

            # Reuse previously created temporary file
            :> "$DRESULT"

            #  Give extra parameters to curl (custom HTTP headers, ...)
            if ANAME=$(module_config_need_extra "$MODULE"); then
                local OPTION
                for OPTION in "${!ANAME}"; do
                    if [[ $OPTION = '-J' || $OPTION = '--remote-header-name' ]]; then
                        log_debug "ignoring extra curl option: '$OPTION'"
                    elif [[ $OPTION = '-O' || $OPTION = '--remote-name' ]]; then
                        log_debug "ignoring extra curl option: '$OPTION'"
                    else
                        log_debug "adding extra curl option: '$OPTION'"
                        CURL_ARGS+=("$OPTION")
                    fi
                done
            fi

            if module_config_need_cookie "$MODULE"; then
                if COOKIE_FILE=$(create_tempfile); then
                    echo "$COOKIE_JAR" > "$COOKIE_FILE"
                    CURL_ARGS+=(-b "$COOKIE_FILE")
                fi
            fi

            DRETVAL=0
            umask 0066 && curl_with_log "${CURL_ARGS[@]}" --fail --globoff \
                -w '%{http_code}\t%{size_download}' \
                -o "$FILENAME_TMP" "$FILE_URL" >"$DRESULT" || DRETVAL=$?
            IFS=$'\t' read -r STATUS FILE_SIZE < "$DRESULT"
            rm -f "$DRESULT"

            if module_config_need_cookie "$MODULE"; then
                rm -f "$COOKIE_FILE"
            fi

            if [ "$DRETVAL" -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
                # Obtained HTTP return status are 200 and 206
                if module_config_resume "$MODULE"; then
                    log_notice 'Partial content downloaded, recall download function'
                    continue
                fi
                DRETVAL=$ERR_NETWORK

            elif [ "$DRETVAL" -eq $ERR_NETWORK ]; then
                if [[ $STATUS -gt 0 ]]; then
                    log_error "Unexpected HTTP code $STATUS"
                fi
            fi

            if [ "$DRETVAL" -ne 0 ]; then
                return $DRETVAL
            fi

            if [[ "$FILE_URL" = file://* ]]; then
                log_notice "delete temporary file: ${FILE_URL:7}"
                rm -f "${FILE_URL:7}"
            elif [[ $FILE_URL =~ ^[Ff][Tt][Pp][Ss]?:// ]]; then
                # Transfer complete
                [[ $STATUS -eq 226  ]] || \
                    log_error "Unexpected FTP code $STATUS, module outdated or upstream updated?"
            elif [[ $STATUS -eq 416 ]]; then
                # If module can resume transfer, we assume here that this error
                # means that file have already been downloaded earlier.
                # We should do a HTTP HEAD request to check file length but
                # a lot of hosters do not allow it.
                if module_config_resume "$MODULE"; then
                    log_error 'Resume error (bad range), skip download'
                else
                    log_error 'Resume error (bad range), restart download'
                    rm -f "$FILENAME_TMP"
                    continue
                fi
            elif [ "${STATUS:0:2}" != 20 ]; then
                log_error "Unexpected HTTP code $STATUS, module outdated or upstream updated?"
                return $ERR_NETWORK
            fi

            chmod 644 "$FILENAME_TMP" 2>/dev/null || log_error "chmod failed: $FILENAME_TMP"

            if [ "$FILENAME_TMP" != "$FILENAME_OUT" ]; then
                test "$TEMP_RENAME" || \
                    log_notice "Moving file to output directory: ${OUT_DIR:-.}"
                mv -f "$FILENAME_TMP" "$FILENAME_OUT" 2>/dev/null || log_error "mv failed: $FILENAME_TMP"
            fi

            mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" OK "$FILENAME_OUT"
        fi

        # Post-processing script (executed in a subshell)
        if [ -n "$POST_COMMAND" ]; then
            COOKIE_FILE=$(create_tempfile) && echo "$COOKIE_JAR" > "$COOKIE_FILE"
            DRETVAL=0
            (exec "$POST_COMMAND" "$MODULE" "$URL_ENCODED" "$COOKIE_FILE" \
                "$FILE_URL" "$FILE_NAME") >/dev/null || DRETVAL=$?

            test -f "$COOKIE_FILE" && rm -f "$COOKIE_FILE"

            if [ $DRETVAL -ne 0 ]; then
                log_error "Post-processing script exited with status $DRETVAL, continue anyway"
            fi
        fi

        # Pretty print results
        local -a DATA=("$MODULE" "$FILE_NAME" "$OUT_DIR" "$COOKIE_JAR" \
                    "$URL_ENCODED" "$FILE_URL" "$FILE_SIZE")
        pretty_print $INDEX DATA[@] "${PRINTF_FORMAT:-%F%n}"

        return 0
    done

    return $ERR_SYSTEM
}

# Plowdown printf format
# ---
# Interpreted sequences are:
# %c: final cookie filename (with output directory)
# %C: %c or empty string if module does not require it
# %d: download (final) url
# %D: download (final) url (JSON string)
# %f: destination (local) filename
# %F: destination (local) filename (with output directory)
# %m: module name
# %s: destination (local) file size (in bytes)
# %u: download (source) url
# %U: download url (JSON string)
# and also:
# %n: newline
# %t: tabulation
# %%: raw %
# ---
#
# Check user given format
# $1: format string
pretty_check() {
    # This must be non greedy!
    local S TOKEN
    S=${1//%[cdDfmsuUCFnt%]}
    TOKEN=$(parse_quiet . '\(%.\)' <<< "$S")
    if [ -n "$TOKEN" ]; then
        log_error "Bad format string: unknown sequence << $TOKEN >>"
        return $ERR_BAD_COMMAND_LINE
    fi
}

# $1: unique number
# $2: array[@] (module, filename, out_dir, cookies, dl_url, final_url, filesize)
# $3: format string
# Note: Don't chmod cookie file (keep strict permissions)
pretty_print() {
    local -ar A=("${!2}")
    local -r CR=$'\n'
    local FMT=$3
    local N COOKIE_FILE

    printf -v N %04d $(($1))
    test "${FMT#*%%}" != "$FMT" && FMT=$(replace_all '%%' "%raw" <<< "$FMT")

    # FIXME: ${A[2]} could contain %? patterns
    if test "${FMT#*%F}" != "$FMT"; then
        if test "${A[2]}"; then
            FMT=$(replace_all '%F' "${A[2]}/%f" <<< "$FMT")
        else
            FMT=$(replace_all '%F' '%f' <<< "$FMT")
        fi
    fi

    # Note: Drop "HttpOnly" attribute, as it is not covered in the RFCs
    if test "${FMT#*%c}" != "$FMT"; then
        if test "${A[2]}"; then
            COOKIE_FILE="${A[2]}/plowdown-cookies-$N.txt"
        else
            COOKIE_FILE="plowdown-cookies-$N.txt"
        fi
        sed -e 's/^#HttpOnly_//' <<< "${A[3]}" > "$COOKIE_FILE"
        FMT=$(replace_all '%c' "${COOKIE_FILE#./}" <<< "$FMT")
    fi
    if test "${FMT#*%C}" != "$FMT"; then
        if module_config_need_cookie "${A[0]}"; then
            if test "${A[2]}"; then
                COOKIE_FILE="${A[2]}/plowdown-cookies-$N.txt"
            else
                COOKIE_FILE="plowdown-cookies-$N.txt"
            fi
            sed -e 's/^#HttpOnly_//' <<< "${A[3]}" > "$COOKIE_FILE"
        else
            COOKIE_FILE=''
        fi
        FMT=$(replace_all '%C' "$COOKIE_FILE" <<< "$FMT")
    fi

    handle_tokens "$FMT" '%raw,%' '%t,	' "%n,$CR" \
        "%m,${A[0]}" "%f,${A[1]}" "%u,${A[4]}" "%d,${A[5]}" \
        "%s,${A[6]}" "%U,$(json_escape "${A[4]}")" "%D,$(json_escape "${A[5]}")"
}

#
# Main
#

# Check interpreter
if (( ${BASH_VERSINFO[0]} * 100 + ${BASH_VERSINFO[1]} <= 400 )); then
    echo 'plowdown: Your shell is too old. Bash 4.1+ is required.' >&2
    echo "plowdown: Your version is $BASH_VERSION" >&2
    exit 1
fi

if [[ $SHELLOPTS = *posix* ]]; then
    echo "plowdown: Your shell is in POSIX mode, this will not work." >&2
    exit 1
fi

# Get library directory
LIBDIR=$(absolute_path "$0")
readonly LIBDIR
TMPDIR=${TMPDIR:-/tmp}

set -e # enable exit checking

source "$LIBDIR/core.sh"

declare -a MODULES=()
eval "$(get_all_modules_list download)" || exit
for MODULE in "${!MODULES_PATH[@]}"; do
    source "${MODULES_PATH[$MODULE]}"
    MODULES+=("$MODULE")
done

# Process command-line (plowdown early options)
eval "$(process_core_options 'plowdown' "$EARLY_OPTIONS" "$@")" || exit

test "$HELPFUL" && { usage 1; exit 0; }
test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

if test "$ALLMODULES"; then
    for MODULE in "${MODULES[@]}"; do echo "$MODULE"; done
    exit 0
fi

# Get configuration file options. Command-line is partially parsed.
test -z "$NO_PLOWSHARERC" && \
    process_configfile_options '[Pp]lowdown' "$MAIN_OPTIONS" "$EXT_PLOWSHARERC"

declare -a COMMAND_LINE_MODULE_OPTS COMMAND_LINE_ARGS RETVALS
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}")

# Process command-line (plowdown options).
# Note: Ignore returned UNUSED_ARGS[@], it will be empty.
eval "$(process_core_options 'plowdown' "$MAIN_OPTIONS" "${UNUSED_OPTS[@]}")" || exit

# Verify verbose level
if [ -n "$QUIET" ]; then
    declare -r VERBOSE=0
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

if [ -n "$NO_COLOR" ]; then
    unset COLOR
else
    declare -r COLOR=yes
fi

if [ "${#MODULES}" -le 0 ]; then
    log_error \
"-------------------------------------------------------------------------------
Your plowshare installation has currently no module.
($PLOWSHARE_CONFDIR/modules.d/ is empty)

In order to use plowdown you must install some modules. Here is a quick start:
$ plowmod --install
-------------------------------------------------------------------------------"
fi

if [ $# -lt 1 ]; then
    log_error 'plowdown: no URL specified!'
    log_error "plowdown: try \`plowdown --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

log_report_info "$LIBDIR"
log_report "plowdown version $VERSION"

if [ -n "$EXT_PLOWSHARERC" ]; then
    if [ -n "$NO_PLOWSHARERC" ]; then
        log_notice 'plowdown: --no-plowsharerc selected and prevails over --plowsharerc'
    else
        log_notice 'plowdown: using alternate configuration file'
    fi
fi

if [ -n "$TEMP_DIR" ]; then
    TMPDIR=${TEMP_DIR%/}
    log_notice "Temporary directory: $TMPDIR"
fi

if [ -n "$OUTPUT_DIR" ]; then
    log_notice "Output directory: ${OUTPUT_DIR%/}"
elif [ ! -w "$PWD" ]; then
    log_notice 'WARNING: Current directory is not writable, you may experience troubles.'
fi

if [ -n "$MIN_LIMIT_SPACE" ]; then
    DISKMON=$(disk_mount_point "${OUTPUT_DIR:-$PWD}") || exit
fi

if [ -n "$PRINTF_FORMAT" ]; then
    pretty_check "$PRINTF_FORMAT" || exit
elif [ -n "$SKIP_FINAL" -a -z "$POST_COMMAND" ]; then
    log_notice 'plowdown: using --skip-final without --printf is probably not what you want'
fi

# Print chosen options
[ -n "$NOOVERWRITE" ] && log_debug 'plowdown: --no-overwrite selected'

if [ -n "$CAPTCHA_PROGRAM" ]; then
    log_debug 'plowdown: --captchaprogram selected'
fi

if [ -n "$CAPTCHA_METHOD" ]; then
    captcha_method_translate "$CAPTCHA_METHOD" || exit
    log_notice "plowdown: force captcha method ($CAPTCHA_METHOD)"
else
    [ -n "$CAPTCHA_9KWEU" ] && log_debug 'plowdown: --9kweu selected'
    [ -n "$CAPTCHA_ANTIGATE" ] && log_debug 'plowdown: --antigate selected'
    [ -n "$CAPTCHA_BHOOD" ] && log_debug 'plowdown: --captchabhood selected'
    [ -n "$CAPTCHA_DEATHBY" ] && log_debug 'plowdown: --deathbycaptcha selected'
fi

if [ -n "$EXT_CURLRC" ]; then
    if [ -n "$NO_CURLRC" ]; then
        log_notice 'plowdown: --no-curlrc selected and prevails over --curlrc'
    else
        log_notice 'plowdown: using alternate curl configuration file'
    fi
elif [ -z "$NO_CURLRC" -a -f "$HOME/.curlrc" ]; then
    log_debug 'using local ~/.curlrc'
fi

MODULE_OPTIONS=$(get_all_modules_options MODULES[@] DOWNLOAD)

# Process command-line (all module options)
eval "$(process_all_modules_options 'plowdown' "$MODULE_OPTIONS" \
    "${UNUSED_OPTS[@]}")" || exit

# Prepend here to keep command-line order
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}" "${COMMAND_LINE_ARGS[@]}")
COMMAND_LINE_MODULE_OPTS=("${UNUSED_OPTS[@]}")

if [ ${#COMMAND_LINE_ARGS[@]} -eq 0 ]; then
    log_error 'plowdown: no URL specified!'
    log_error "plowdown: try \`plowdown --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

set_exit_trap

# Remember last host because hosters may require waiting between
# successive downloads.
PREVIOUS_HOST=none

# Only used when CACHE policy is session (default).
# Use an associative array to not have duplicated modules.
declare -A CACHED_MODULES

# Count downloads (1-based index)
declare -i INDEX=1

for ITEM in "${COMMAND_LINE_ARGS[@]}"; do
    mapfile -t ELEMENTS < <(process_item "$ITEM")

    TYPE=${ELEMENTS[0]}
    unset ELEMENTS[0]

    for URL in "${ELEMENTS[@]}"; do
        MRETVAL=0

        # See --min-space
        if [ -n "$MIN_LIMIT_SPACE" ]; then
            disk_check "$DISKMON" $MIN_LIMIT_SPACE || break 2
        fi

        # Detect (simple) redirection services
        # http://8bbd5066.redir.com/url/http://www.hoster.com/file/921AFF48
        if [[ $URL =~ ^[Hh][Tt][Tt][Pp][Ss]?://.+([Hh][Tt][Tt][Pp][Ss]?://.*)$ ]]; then
            URL=${BASH_REMATCH[1]}
            log_notice "This seems to be a redirection url. Trying with: '$URL'"
        fi

        # Sanity check
        if [[ ${URL%/} =~ ^[Hh][Tt][Tt][Pp][Ss]?://(www\.)?[[:alnum:]]+\.[[:alpha:]]{2,3}$ ]]; then
            log_notice 'You seem to have entered a basename link without any path/query. Please check if your link is valid.'
            URL="${URL%/}/"
            # Force error even if $MODULE detected
            MRETVAL=$ERR_NOMODULE
        fi

        MODULE=$(get_module "$URL" MODULES[@]) || true

        if [ -z "$MODULE" ]; then
            MRETVAL=0
            if match_remote_url "$URL"; then
                # Test for simple HTTP 30X redirection
                # (disable User-Agent because some proxy can fake it)
                log_notice 'No module found, try simple redirection'

                URL_ENCODED=$(uri_encode <<< "$URL")
                HEADERS=$(curl --user-agent '' --head "$URL_ENCODED") || true

                if [ -n "$HEADERS" ]; then
                    URL_TEMP=$(grep_http_header_location_quiet <<< "$HEADERS")

                    if [ -n "$URL_TEMP" ]; then
                        MODULE=$(get_module "$URL_TEMP" MODULES[@]) || MRETVAL=$?
                        test "$MODULE" && URL=$URL_TEMP
                    elif test "$NO_MODULE_FALLBACK"; then
                        log_notice 'No module found, do a simple HTTP GET as requested'
                        MODULE='module_null'
                    else
                        [[ $URL =~ [Hh][Tt][Tt][Pp][Ss]?://([[:digit:]]{1,3}\.){3}[[:digit:]]{1,3} ]] && \
                            log_notice 'Raw IPv4 address not expected. Provide an URL with a DNS name.'
                        log_debug "remote server reply: $(echo "$HEADERS" | first_line | tr -d '\r\n')"
                        MRETVAL=$ERR_NOMODULE
                    fi
                else
                    MRETVAL=$ERR_NOMODULE
                fi

            # Check for FTP
            elif [[ $URL =~ ^[Ff][Tt][Pp][Ss]?:// ]]; then
                if test "$NO_MODULE_FALLBACK"; then
                    log_notice 'No module found, do a simple FTP GET as requested'
                    MODULE='module_null'
                else
                    declare LIST
                    [ "$TYPE" = 'file' ] && LIST=" (in $ITEM)"
                    log_debug "Skip: '$URL'$LIST is a FTP link. You may use --fallback option."
                    MRETVAL=$ERR_NOMODULE
                fi
            else
                log_debug "Skip: '$URL' (in $ITEM) doesn't seem to be a link"
                MRETVAL=$ERR_NOMODULE
            fi
        fi

        if [ $MRETVAL -ne 0 ]; then
            if match_remote_url "$URL"; then
                if [ -z "$MODULE" ]; then
                    log_error "Skip: no module for URL ($(basename_url "$URL"))"
                else
                    log_error "Skip: invalid URL (${URL%/}) but module is supported ($MODULE)"
                fi
            fi

            # Check if plowlist can handle $URL
            if [[ ! $MODULES2 ]]; then
                declare -a MODULES2=()
                eval "$(get_all_modules_list list download)" || exit
                for MODULE in "${!MODULES_PATH[@]}"; do
                    source "${MODULES_PATH[$MODULE]}"
                    MODULES2+=("$MODULE")
                done
            fi
            MODULE=$(get_module "$URL" MODULES2[@]) || true
            if [ -n "$MODULE" ]; then
                log_notice "Note: This URL ($MODULE) is supported by plowlist"
            fi

            RETVALS+=($MRETVAL)
            mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" NOMODULE
        else
            # Get configuration file module options
            test -z "$NO_PLOWSHARERC" && \
                process_configfile_module_options '[Pp]lowdown' "$MODULE" DOWNLOAD "$EXT_PLOWSHARERC"

            eval "$(process_module_options "$MODULE" DOWNLOAD \
                "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

            [ "${#UNUSED_OPTS[@]}" -eq 0 ] || \
                log_notice "$MODULE: unused command line switches: ${UNUSED_OPTS[*]}"

            # Module storage policy (part 1/2)
            if [ "$CACHE" = 'none' ]; then
                storage_reset
            elif [ "$CACHE" != 'shared' ]; then
                [[ ${CACHED_MODULES["$MODULE"]} ]] || CACHED_MODULES["$MODULE"]=1
            fi

            ${MODULE}_vars_set
            download "$MODULE" "$URL" "$TYPE" "$ITEM" "${OUTPUT_DIR%/}" \
                "${MAXRETRIES:-2}" "$PREVIOUS_HOST" || MRETVAL=$?
            ${MODULE}_vars_unset

            # Link explicitly skipped
            if [ -n "$PRE_COMMAND" -a $MRETVAL -eq $ERR_NOMODULE ]; then
                PREVIOUS_HOST=none
                MRETVAL=0
            else
                PREVIOUS_HOST=$(basename_url "$URL")
            fi

            RETVALS+=($MRETVAL)
            (( ++INDEX ))
        fi
    done
done

# Module storage policy (part 2/2)
if [ "$CACHE" != 'shared' ]; then
    for MODULE in "${!CACHED_MODULES[@]}"; do storage_reset; done
fi

if [ ${#RETVALS[@]} -eq 0 ]; then
    exit 0
elif [ ${#RETVALS[@]} -eq 1 ]; then
    exit ${RETVALS[0]}
else
    log_debug "retvals:${RETVALS[*]}"
    # Drop success values
    RETVALS=(${RETVALS[@]/#0*} -$ERR_FATAL_MULTIPLE)

    exit $((ERR_FATAL_MULTIPLE + ${RETVALS[0]}))
fi
