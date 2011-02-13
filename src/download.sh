#!/bin/bash
#
# Download files from file sharing servers
# Copyright (c) 2010 Arnau Sanchez
#
# Output filenames are printed on standard output (one per line).
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

set -e

VERSION="SVN-snapshot"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,,version,,Return plowdown version
VERBOSE,v:,verbose:,LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
CHECK_LINK,c,check-link,,Check if a link exists and return
MARK_DOWN,m,mark-downloaded,,Mark downloaded links in (regular) FILE arguments
NOOVERWRITE,x,no-overwrite,,Do not overwrite existing files
GET_MODULE,,get-module,,Get module(s) for URL(s)
OUTPUT_DIR,o:,output-directory:,DIRECTORY,Directory where files will be saved
TEMP_DIR,,temp-directory:,DIRECTORY,Directory where files are temporarily downloaded
LIMIT_RATE,r:,limit-rate:,SPEED,Limit speed to bytes/sec (suffixes: k=Kb, m=Mb, g=Gb)
INTERFACE,i:,interface,IFACE,Force IFACE interface
TIMEOUT,t:,timeout:,SECS,Timeout after SECS seconds of waits
MAXRETRIES,,max-retries:,N,Set maximum retries for loops
NOARBITRARYWAIT,,no-arbitrary-wait,,Do not wait on temporarily unavailable file with no time delay information
GLOBAL_COOKIES,,cookies:,FILE,Force use of a cookies file (login will be skipped)
DOWNLOAD_APP,,run-download:,COMMAND,run down command (interpolations: %url, %filename, %cookies)
DOWNLOAD_INFO,,download-info-only:,STRING,Echo string (interpolations: %url, %filename, %cookies) for each link
"


# Error codes
# On multiple arguments, lower error (1..) is the final exit code.
ERROR_CODE_OK=0
ERROR_CODE_FATAL=1
ERROR_CODE_NOMODULE=2
ERROR_CODE_DEAD_LINK=3
ERROR_CODE_TEMPORAL_PROBLEM=4
ERROR_CODE_UNKNOWN_ERROR=5
ERROR_CODE_TIMEOUT_ERROR=6
ERROR_CODE_NETWORK_ERROR=7
ERROR_CODE_PASSWORD_REQUIRED=8

# - Results are similar to "readlink -f" (available on GNU but not BSD)
# - If '-P' flags (of cd) are removed directory symlinks won't be
#   translated (but results are correct too)
# - Assume that $1 is correct (don't check for infinite loop)
absolute_path() {
    local SAVED_PWD="$PWD"
    TARGET="$1"

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
        DIR="$PWD"
    done

    if [ -f "$TARGET" ]; then
        DIR=$(dirname "$TARGET")
    else
        DIR="$TARGET"
    fi

    cd -P "$DIR"
    TARGET="$PWD"
    cd "$SAVED_PWD"
    echo "$TARGET"
}

# Guess if item is a rapidshare URL, a generic URL (to start a download)
# or a file with links (discard empty/repeated lines and comments)-
process_item() {
    local ITEM=$1
    if match "^http://" "$ITEM"; then
        echo "url|$ITEM"
    elif [ -f "$ITEM" ]; then
        grep -v "^[[:space:]]*\(#\|$\)" -- "$ITEM" | while read URL; do
            test "$ITEM" != "-" -a -f "$ITEM" &&
                TYPE="file" || TYPE="url"
            echo "$TYPE|$URL"
        done
    else
        log_error "cannot stat '$ITEM': No such file or directory"
    fi
}

# Print usage
usage() {
    echo "Usage: plowdown [OPTIONS] [MODULE_OPTIONS] URL|FILE [URL|FILE ...]"
    echo
    echo "  Download files from file sharing servers."
    echo "  Available modules:" $(echo "$MODULES" | tr '\n' ' ')
    echo
    echo "Global options:"
    echo
    debug_options "$OPTIONS" "  "
    debug_options_for_modules "$MODULES" "DOWNLOAD"
}

# If MARK_DOWN is enabled, mark status of link (inside file or to stdout).
mark_queue() {
    local TYPE=$1
    local MARK_DOWN=$2
    local FILELIST=$3
    local URL=$4
    local TEXT=$5
    local TAIL=$6

    test -z "$MARK_DOWN" && return 0

    if test "$TYPE" = "file"; then
        TAIL=${TAIL//%/\\%}
        URL=${URL//%/\\%}

        sed -i -e "s%^[[:space:]]*\($URL\)[[:space:]]*$%#$TEXT \1$TAIL%" "$FILELIST" &&
            log_notice "link marked in file: $FILELIST (#$TEXT)" ||
            log_error "failed marking link in file: $FILELIST (#$TEXT)"
    else
        echo "#${TEXT} $URL"
    fi
}

# Create an alternative filename
# Pattern is filename.1
#
# $1: filename (with or without path)
# stdout: non existing filename
create_alt_filename() {
    local FILENAME="$1"
    local count=1

    while [ "$count" -le 99 ]; do
        if [ ! -f "${FILENAME}.$count" ]; then
            FILENAME="${FILENAME}.$count"
            break
        fi
        ((count++))
    done
    echo "$FILENAME"
}

download() {
    local MODULE=$1
    local URL=$2
    local DOWNLOAD_APP=$3
    local LIMIT_RATE=$4
    local TYPE=$5
    local MARK_DOWN=$6
    local TEMP_DIR=$7
    local OUTPUT_DIR=$8
    local CHECK_LINK=$9
    local TIMEOUT=${10}
    local MAXRETRIES=${11}
    local NOARBITRARYWAIT=${12}
    local DOWNLOAD_INFO=${13}
    shift 13

    FUNCTION=${MODULE}_download
    log_debug "start download ($MODULE): $URL"
    timeout_init $TIMEOUT
    retry_limit_init $MAXRETRIES

    while true; do
        local DRETVAL=0
        RESULT=$($FUNCTION "$@" "$(echo "$URL" | strip)") || DRETVAL=$?
        { read FILE_URL; read FILENAME; read COOKIES; } <<< "$RESULT" || true

        if test $DRETVAL -eq 255 -a "$CHECK_LINK"; then
            log_notice "Link active: $URL"
            echo "$URL"
            break
        elif test $DRETVAL -eq 253; then
            log_notice "Warning: file link is alive but not currently available"
            return $ERROR_CODE_TEMPORAL_PROBLEM
        elif test $DRETVAL -eq 254; then
            log_notice "Warning: file link is not alive"
            mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" "NOTFOUND"
            return $ERROR_CODE_DEAD_LINK
        elif test $DRETVAL -eq 2; then
            log_error "delay limit reached (${FUNCTION})"
            return $ERROR_CODE_TIMEOUT_ERROR
        elif test $DRETVAL -eq 3; then
            log_error "retry limit reached (${FUNCTION})"
            return $ERROR_CODE_TIMEOUT_ERROR
        elif test $DRETVAL -eq 4; then
            log_error "password required (${FUNCTION})"
            mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" "PASSWORD"
            return $ERROR_CODE_PASSWORD_REQUIRED
        elif test $DRETVAL -ne 0 -o -z "$FILE_URL"; then
            log_error "failed inside ${FUNCTION}()"
            return $ERROR_CODE_UNKNOWN_ERROR
        fi

        log_notice "File URL: $FILE_URL"

        if test -z "$FILENAME"; then
            FILENAME=$(basename_file "$FILE_URL" | sed "s/?.*$//" | tr -d '\r\n' |
              html_to_utf8 | uri_decode)
        fi
        log_notice "Filename: $FILENAME"

        DRETVAL=0

        # External download or curl regular download
        if test "$DOWNLOAD_APP"; then
            test "$OUTPUT_DIR" && FILENAME="$OUTPUT_DIR/$FILENAME"
            COMMAND=$(echo "$DOWNLOAD_APP" |
                replace "%url" "$FILE_URL" |
                replace "%filename" "$FILENAME" |
                replace "%cookies" "$COOKIES")
            log_notice "Running command: $COMMAND"
            eval $COMMAND || DRETVAL=$?
            test "$COOKIES" && rm "$COOKIES"
            log_notice "Command exited with retcode: $DRETVAL"
            test $DRETVAL -eq 0 || break
        elif test "$DOWNLOAD_INFO"; then
            test "$OUTPUT_DIR" && FILENAME="$OUTPUT_DIR/$FILENAME"
            local OUTPUT_COOKIES=""
            if test "$COOKIES"; then
                # move temporal cookies (standard tempfiles are automatically deleted)
                OUTPUT_COOKIES="${TMPDIR:-/tmp}/$(basename_file $0).cookies.$$.txt"
                mv "$COOKIES" "$OUTPUT_COOKIES"
            fi
            echo "$DOWNLOAD_INFO" |
                replace "%url" "$FILE_URL" |
                replace "%filename" "$FILENAME" |
                replace "%cookies" "$OUTPUT_COOKIES"
        else
            local TEMP_FILENAME
            if test "$TEMP_DIR"; then
                TEMP_FILENAME="$TEMP_DIR/$FILENAME"
                mkdir -p "$TEMP_DIR"
                log_notice "Downloading file to temporal directory: $TEMP_FILENAME"
            else
                TEMP_FILENAME="$FILENAME"
            fi

            CURL=("curl")
            FILE_URL=$(echo "$FILE_URL" | uri_encode)
            continue_downloads "$MODULE" && CURL=("${CURL[@]}" "-C -")
            test "$LIMIT_RATE" && CURL=("${CURL[@]}" "--limit-rate $LIMIT_RATE")
            test "$COOKIES" && CURL=("${CURL[@]}" -b $COOKIES)
            test "$NOOVERWRITE" -a -f "$TEMP_FILENAME" && \
                TEMP_FILENAME=$(create_alt_filename "$TEMP_FILENAME")

            # Force (temporarily) debug verbose level to dispay curl download progress
            log_report ${CURL[@]} -w "%{http_code}" -y60 -f --globoff -o "$TEMP_FILENAME" "$FILE_URL"
            CODE=$(with_log ${CURL[@]} -w "%{http_code}" -y60 -f --globoff \
                -o "$TEMP_FILENAME" "$FILE_URL") || DRETVAL=$?

            test "$COOKIES" && rm $COOKIES

            if [ $DRETVAL -eq 22 -o $DRETVAL -eq 18 -o $DRETVAL -eq 28 ]; then
                local WAIT=60
                log_error "curl failed with retcode $DRETVAL"
                log_error "retry after a safety wait ($WAIT seconds)"
                sleep $WAIT
                continue
            elif [ $DRETVAL -ne 0 ]; then
                log_error "failed downloading $URL"
                return $ERROR_CODE_NETWORK_ERROR
            fi

            if [ "$CODE" = 416 ]; then
                log_error "Resume error (bad range), restart download"
                rm -f "$TEMP_FILENAME"
                continue
            elif ! match "20." "$CODE"; then
                log_error "unexpected HTTP code $CODE"
                continue
            fi

            if test "$OUTPUT_DIR" != "$TEMP_DIR"; then
                mkdir -p "$(dirname "$OUTPUT_DIR")"
                log_notice "Moving file to output directory: ${OUTPUT_DIR:-.}"
                mv "$TEMP_FILENAME" "${OUTPUT_DIR:-.}" || true
            fi

            # Echo downloaded file path
            FN=$(basename_file "$TEMP_FILENAME")
            OUTPUT_PATH=$(test "$OUTPUT_DIR" && echo "$OUTPUT_DIR/$FN" || echo "$FN")
            echo $OUTPUT_PATH
        fi
        mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" "" "|$OUTPUT_PATH"
        break
    done
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/core.sh"
MODULES=$(grep_config_modules 'download') || exit 1
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

MODULE_OPTIONS=$(get_modules_options "$MODULES" DOWNLOAD)
eval "$(process_options plowshare "$OPTIONS $MODULE_OPTIONS" "$@")"

# Verify verbose level
if [ -n "$QUIET" ]; then
    VERBOSE=0
elif [ -n "$VERBOSE" ]; then
    [ "$VERBOSE" -gt "4" ] && VERBOSE=4
else
    VERBOSE=2
fi

test "$HELP" && { usage; exit $ERROR_CODE_OK; }
test "$GETVERSION" && { echo "$VERSION"; exit $ERROR_CODE_OK; }
test $# -ge 1 || { usage; exit $ERROR_CODE_FATAL; }
set_exit_trap

if [ -n "$OUTPUT_DIR" ]; then
    OUTPUT_DIR=$(echo "$OUTPUT_DIR" | sed -e "s/\/$//")
    log_error "output directory: $OUTPUT_DIR"
fi

RETVALS=()
for ITEM in "$@"; do
    for INFO in $(process_item "$ITEM"); do
        IFS="|" read TYPE URL <<< "$INFO"
        MODULE=$(get_module "$URL" "$MODULES")
        if test -z "$MODULE"; then
            log_error "no module for URL: $URL"
            RETVALS=("${RETVALS[@]}" $ERROR_CODE_NOMODULE)
            mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" "NOMODULE"
            continue
        elif test "$GET_MODULE"; then
            echo "$MODULE"
            continue
        fi
        download "$MODULE" "$URL" "$DOWNLOAD_APP" "$LIMIT_RATE" "$TYPE" \
            "$MARK_DOWN" "$TEMP_DIR" "$OUTPUT_DIR" "$CHECK_LINK" "$TIMEOUT" \
            "$MAXRETRIES" "$NOARBITRARYWAIT" "$DOWNLOAD_INFO" "${UNUSED_OPTIONS[@]}" ||
              RETVALS=("${RETVALS[@]}" "$?")
    done
done

exit $(echo ${RETVALS[*]:-0} | xargs -n1 | sort -n | head -n1)
