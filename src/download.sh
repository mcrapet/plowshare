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
#

# Download files from file sharing servers.
#
# Output filenames path to standard output (one per line).
#
# Dependencies: curl, getopt, recode
#
# Web: http://code.google.com/p/plowshare
# Contact: Arnau Sanchez <tokland@gmail.com>.
#
set -e

VERSION="0.9.1"
MODULES="rapidshare megaupload 2shared badongo mediafire 4shared zshare depositfiles storage_to uploaded_to uploading netload_in usershare sendspace x7_to hotfile divshare dl_free_fr loadfiles humyo filefactory"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,v,version,,Return plowdown version
QUIET,q,quiet,,Don't print debug messages
CHECK_LINK,c,check-link,,Check if a link exists and return
MARK_DOWN,m,mark-downloaded,,Mark downloaded links in (regular) FILE arguments
GET_MODULE,,get-module,,Get module(s) for URL(s)
OUTPUT_DIR,o:,output-directory:,DIRECTORY,Directory where files will be saved
TEMP_DIR,,temp-directory:,DIRECTORY,Directory where files are temporarily downloaded
LIMIT_RATE,r:,limit-rate:,SPEED,Limit speed to bytes/sec (suffixes: k=Kb, m=Mb, g=Gb)
INTERFACE,i:,interface,IFACE,Force IFACE interface
TIMEOUT,t:,timeout:,SECS,Timeout after SECS seconds of waits
MAXRETRIES,,max-retries:,N,Set maximum retries for loops
DOWNLOAD_APP,,run-download:,COMMAND,run down command (interpolations: %filename, %cookies, %url)'
"

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

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/lib.sh"
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Guess if item is a rapidshare URL, a generic URL (to start a download)
# or a file with links (discard empty/repeated lines and comments)-
#
process_item() {
    ITEM=$1
    if match "^http://" "$ITEM"; then
        echo "url|$ITEM"
    elif [ -f "$ITEM" ]; then
        grep -v "^[[:space:]]*\(#\|$\)" -- "$ITEM" | while read URL; do
            test "$ITEM" != "-" -a -f "$ITEM" &&
                TYPE="file" || TYPE="url"
            echo "$TYPE|$URL"
        done
    else
        debug "cannot stat '$ITEM': No such file or directory"
    fi
}

# Print usage
#
usage() {
    debug "Usage: plowdown [OPTIONS] [MODULE_OPTIONS] URL|FILE [URL|FILE ...]"
    debug
    debug "  Download files from file sharing servers."
    debug
    debug "  Available modules: $MODULES"
    debug
    debug "Global options:"
    debug
    debug_options "$OPTIONS" "  "
    debug_options_for_modules "$MODULES" "DOWNLOAD"
}

# If MARK_DOWN enabled and it's a file, comment out URL (with optional TEXT)
mark_queue() {
    local TYPE=$1; local MARK_DOWN=$2; FILE=$3; local URL=$4; local TEXT=$5
    test "$TYPE" = "file" -a "$MARK_DOWN" || return 0
    sed -i -e "s|^[[:space:]]*\($URL\)[[:space:]]*$|#$TEXT \1|" "$FILE" &&
        debug "link marked in file: $FILE (#$TEXT)" ||
        error "failed marking link in file: $FILE (#$TEXT)"
}


# download MODULE URL FUNCTION_OPTIONS
download() {
    local MODULE=$1
    local URL=$2
    local LINK_ONLY=$3
    local LIMIT_RATE=$4
    local TYPE=$5
    local MARK_DOWN=$6
    local TEMP_DIR=$7
    local OUTPUT_DIR=$8
    local CHECK_LINK=$9
    local TIMEOUT=${10}
    local MAXRETRIES=${11}
    shift 11

    FUNCTION=${MODULE}_download
    debug "start download ($MODULE): $URL"
    timeout_init $TIMEOUT
    retry_limit_init $MAXRETRIES

    while true; do
        local DRETVAL=0
        RESULT=$($FUNCTION "$@" "$URL") || DRETVAL=$?
        { read FILE_URL; read FILENAME; read COOKIES; } <<< "$RESULT" || true

        if test $DRETVAL -eq 255 -a "$CHECK_LINK"; then
            debug "Link active: $URL"
            echo "$URL"
            break
        elif test $DRETVAL -eq 254; then
            debug "Warning: file link is not alive"
            mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" "NOTFOUND"
            # Don't set RETVAL, a dead link is not considerer an error¡
            break
        elif test $DRETVAL -eq 3; then
            error "retry limit reached (${FUNCTION})"
            RETVAL=$DERROR
            break
        elif test $DRETVAL -ne 0 -o -z "$FILE_URL"; then
            error "failed inside ${FUNCTION}()"
            RETVAL=$DERROR
            break
        fi

        debug "File URL: $FILE_URL"

        if test -z "$FILENAME"; then
            FILENAME=$(basename "$FILE_URL" | sed "s/?.*$//" | tr -d '\r\n' | recode html..utf8)
        fi
        debug "Filename: $FILENAME"

        local DRETVAL=0
        if test "$DOWNLOAD_APP"; then
            test "$OUTPUT_DIR" && FILENAME="$OUTPUT_DIR/$FILENAME"
            COMMAND=$(echo "$DOWNLOAD_APP" |
                replace "%url" "$FILE_URL" |
                replace "%filename" "$FILENAME" |
                replace "%cookies" "$COOKIES")
            debug "Running command: $COMMAND"
            eval "$COMMAND" || DRETVAL=$?
            test "$COOKIES" && rm "$COOKIES"
            debug "Command exited with retcode: $DRETVAL"
            test $DRETVAL -eq 0 || break
        else
            local TEMP_FILENAME
            if test "$TEMP_DIR"; then
                TEMP_FILENAME="$TEMP_DIR/$FILENAME"
                debug "Downloading file to temporal directory: $TEMP_FILENAME"
            else
                TEMP_FILENAME="$FILENAME"
            fi
            CURL=("curl")
            continue_downloads "$MODULE" && CURL=($CURL "-C -")
            test "$LIMIT_RATE" && CURL=($CURL "--limit-rate $LIMIT_RATE")
            test "$COOKIES" && CURL=($CURL -b $COOKIES)
            CODE=$(${CURL[@]} -w "%{http_code}" -y60 -f --globoff \
                              -o "$TEMP_FILENAME" "$FILE_URL") || DRETVAL=$?
            test "$COOKIES" && rm $COOKIES
            if [ $DRETVAL -eq 22 -o $DRETVAL -eq 18 -o $DRETVAL -eq 28 ]; then
                local WAIT=60
                debug "curl failed with retcode $DRETVAL"
                debug "retry after a safety wait ($WAIT seconds)"
                sleep $WAIT
                continue
            elif [ $DRETVAL -ne 0 ]; then
                error "failed downloading $URL"
                RETVAL=$DERROR
                break
            fi
            if ! match "20." "$CODE"; then
                error "unexpected HTTP code $CODE"
                continue
            fi
            if test "$OUTPUT_DIR" != "$TEMP_DIR"; then
                debug "Moving file to output directory: ${OUTPUT_DIR:-.}"
                mv "$TEMP_FILENAME" "${OUTPUT_DIR:-.}" || true
            fi
            # Echo downloaded file path
            test "$OUTPUT_DIR" && echo "$OUTPUT_DIR/$FILENAME" ||
                echo "$FILENAME"
        fi
        mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" ""
        break
    done
}

# Main
#

MODULE_OPTIONS=$(get_modules_options "$MODULES" DOWNLOAD)
eval "$(process_options plowshare "$OPTIONS $MODULE_OPTIONS" "$@")"

test "$HELP" && { usage; exit 2; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

test $# -ge 1 || { usage; exit 1; }

# Exit with code 0 if all links are downloaded succesfuly (DERROR otherwise)
DERROR=5
RETVAL=0
for ITEM in "$@"; do
    for INFO in $(process_item "$ITEM"); do
        IFS="|" read TYPE URL <<< "$INFO"
        MODULE=$(get_module "$URL" "$MODULES")
        if test -z "$MODULE"; then
            debug "no module for URL: $URL"
            RETVAL=$DERROR
            mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" "NOMODULE"
            continue
        elif test "$GET_MODULE"; then
            echo "$MODULE"
            continue
        fi
        download "$MODULE" "$URL" "$LINK_ONLY" "$LIMIT_RATE" "$TYPE" \
            "$MARK_DOWN" "$TEMP_DIR" "$OUTPUT_DIR" "$CHECK_LINK" "$TIMEOUT" \
            "$MAXRETRIES" "${UNUSED_OPTIONS[@]}"
    done
done

exit $RETVAL
