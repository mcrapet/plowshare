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
#
set -e

VERSION="0.8.1"
MODULES="rapidshare megaupload 2shared badongo mediafire 4shared zshare depositfiles storage_to uploaded_to letitbit uploading netload_in usershare sendspace"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,v,version,,Return plowdown version
QUIET,q,quiet,,Don't print debug messages
LINK_ONLY,l,link-only,,Return only file link
MARK_DOWN,m,mark-downloaded,,Mark downloaded links in (regular) FILE arguments
OUTPUT_DIR,o:,output-directory:,DIRECTORY,Directory where files will be saved
LIMIT_RATE,r:,--limit-rate:,SPEED,Limit speed to bytes/sec (suffixes: k=Kb, m=Mb, g=Gb)
INTERFACE,i:,interface,IFACE,Force IFACE interface
CHECK_LINK,c,check-link,,Check if a link exists and return
"


# - Results are similar to "readlink -f" (available on GNU but not BSD)
# - If '-P' flags (of cp) are removed directory symlinks won't be
#   translated (but results are correct too)
# - Assume that $1 is correct (don't check for infinite loop)
absolute_path() {
    local saved_pwd="$PWD"
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
    cd $saved_pwd
    echo "$TARGET"
}

# Get library directory
LIBDIR=$(absolute_path "$0")
EXTRASDIR=$LIBDIR/modules/extras

source "$LIBDIR/lib.sh"
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Guess is item is a rapidshare URL, a generic URL (to start a download)
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

# download MODULE URL FUNCTION_OPTIONS
download() {
    local MODULE=$1
    local URL=$2
    local LINK_ONLY=$3
    local LIMIT_RATE=$4
    local TYPE=$5
    local MARK_DOWN=$6
    local OUTPUT_DIR=$7
    local CHECK_LINK=$8
    shift 8

    FUNCTION=${MODULE}_download
    debug "start download ($MODULE): $URL"

    while true; do
        local DRETVAL=0
        RESULT=$($FUNCTION "$@" "$URL") || DRETVAL=$?
        { read FILE_URL; read FILENAME; read COOKIES; } <<< "$RESULT" || true

        if test $DRETVAL -eq 255 -a "$CHECK_LINK"; then
          debug "Link active: $URL"
          echo "$URL"
          break
        elif test $DRETVAL -eq 254; then
          debug "warning: file link is not alive"
          if test "$TYPE" = "file" -a "$MARK_DOWN"; then
              sed -i "s|^[[:space:]]*\($URL\)[[:space:]]*$|#NOTFOUND \1|" "$ITEM" &&
                  debug "link marked as non-downloadable in file: $ITEM" ||
                  error "error marking link as non-downloadable in file: $ITEM"
          fi
          # Don't set RETVAL, a non-found file is not considerer an error
          break
        fi
        test $DRETVAL -ne 0 -o -z "$FILE_URL" &&
            { error "error on function: $FUNCTION"; RETVAL=$DERROR; break; }
        debug "file URL: $FILE_URL"

        if test "$LINK_ONLY"; then
            echo "$FILE_URL"
        else
            CURL=("curl")
            continue_downloads "$MODULE" && CURL=($CURL "-C -")
            test "$LIMIT_RATE" && CURL=($CURL "--limit-rate $LIMIT_RATE")
            test "$COOKIES" && CURL=($CURL -b $COOKIES)
            test -z "$FILENAME" && FILENAME=$(basename "$FILE_URL" |
                sed "s/?.*$//" | tr -d '\r\n' | recode html..utf8)
            test "$OUTPUT_DIR" && FILENAME="$OUTPUT_DIR/$FILENAME"
            local DRETVAL=0
            CODE=$(${CURL[@]} -w "%{http_code}" -y60 -f --globoff -o "$FILENAME" "$FILE_URL") || DRETVAL=$?
            test "$COOKIES" && rm $COOKIES
            if [ $DRETVAL -eq 22 -o $DRETVAL -eq 18 -o $DRETVAL -eq 28 ]; then
                local WAIT=60
                debug "curl failed with retcode $DRETVAL"
                debug "retry after a safety wait ($WAIT seconds)"
                sleep $WAIT
                continue
            elif [ $DRETVAL -ne 0 ]; then
                error "error downloading: $URL"
                RETVAL=$DERROR
                break
            fi
            if ! match "20." "$CODE"; then
                error "error HTTP code: $CODE"
                continue
            fi
            echo "$FILENAME"
        fi

        if test "$TYPE" = "file" -a "$MARK_DOWN"; then
            sed -i "s|^[[:space:]]*\($URL\)[[:space:]]*$|#\1|" "$ITEM" &&
                debug "link marked as downloaded in file: $ITEM" ||
                error "error marking link as downloaded in file: $ITEM"
        fi
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
        test -z "$MODULE" &&
            { debug "no module for URL: $URL"; RETVAL=$DERROR; continue; }
        download "$MODULE" "$URL" "$LINK_ONLY" "$LIMIT_RATE" "$TYPE" \
            "$MARK_DOWN" "$OUTPUT_DIR" "$CHECK_LINK" "${UNUSED_OPTIONS[@]}"
    done
done

exit $RETVAL
