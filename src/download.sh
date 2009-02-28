#!/bin/bash
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
# License: GNU GPL v3.0: http://www.gnu.org/licenses/gpl-3.0-standalone.html
#
set -e

VERSION="0.4.1"
MODULES="rapidshare megaupload 2shared"
OPTIONS="
GETVERSION,v,version,,Return plowdown version
QUIET,q,quiet,,Don't print error nor debug messages 
LINK_ONLY,l,link-only,,Return only file link 
MARK_DOWNLOADED,m,mark-downloaded,,Mark downloaded links in FILE arguments
UPDATE_MEGAUPLOAD_CAPTCHAS,u,update-megaupload-captchas,,Update captchas from JDownloader
"

# Get library directory
LIBDIR=$(dirname "$(readlink -f "$(which "$0")")")
EXTRASDIR=$LIBDIR/modules/extras

source $LIBDIR/lib.sh
for MODULE in $MODULES; do
    source $LIBDIR/modules/$MODULE.sh
done

# Get module name from URL link
#
# $1: URL 
get_module() {
    URL=$1
    MODULES=$2
    for MODULE in $MODULES; do
        VAR=MODULE_$(echo $MODULE | uppercase)_REGEXP_URL
        match "${!VAR}" "$URL" && { echo $MODULE; return; } || true    
    done
    return 1     
}

# Guess is item is a rapidshare URL, a generic URL (to start a download)
# or a file with links (discard empty/repeated lines and comments)- 
#
process_item() {
    ITEM=$1
    if match "^\(http://\)" "$ITEM"; then
        echo "url" "$ITEM"
    else
        grep -v "^[[:space:]]*\(#\|$\)" -- "$ITEM" | while read URL; do
            test "$ITEM" != "-" -a -f "$ITEM" &&
                TYPE="file" || TYPE="url"
            echo "$TYPE" "$URL"
        done
    fi
}

# Print usage
#
usage() {
    debug "Usage: $(basename $0) [OPTIONS] [MODULE_OPTIONS] URL|FILE [URL|FILE ...]"
    debug
    debug "  Download files from file sharing servers."
    debug
    debug "  Available modules: $MODULES"
    debug
    debug "Global options:"
    debug
    debug_options "$OPTIONS" "  "
    debug_options_for_modules "$MODULES" "DOWNLOAD"    
    debug
}

# Main
#

MODULE_OPTIONS=$(get_modules_options "$MODULES" DOWNLOAD)
eval "$(process_options plowshare "$OPTIONS $MODULE_OPTIONS" "$@")"

test "$GETVERSION" && { echo "$VERSION"; exit 0; }
 
if test "$QUIET"; then
    function debug() { :; } 
    function curl() { $(type -P curl) -s "$@"; }
fi

test "$UPDATE_MEGAUPLOAD_CAPTCHAS" && { update_megaupload_captchas; exit 0; } 

test $# -ge 1 || { usage; exit 1; } 

check_exec "curl" || { debug "Fatal error: curl is not installed"; exit 2; }
check_exec "recode" || { debug "Fatal error: recode is not installed"; exit 2; }

# Exit with code 0 if all links are downloaded succesfuly (DERROR otherwise)
DERROR=4
RETVAL=0
for ITEM in "$@"; do
    process_item "$ITEM" | while read TYPE URL; do
        MODULE=$(get_module "$URL" "$MODULES")
        if ! test "$MODULE"; then 
            debug "no module recognizes this URL: $URL"
            RETVAL=$DERROR
            continue
        fi
        FUNCTION=${MODULE}_download 
        if ! check_function "$FUNCTION"; then 
            debug "module does not implement download: $MODULE"
            RETVAL=$DERROR
            continue
        fi
        debug "start download ($MODULE): $URL"
        MODULE_OPTIONS=$(get_options_for_module "$MODULE" "DOWNLOAD")
        FILE_URL=$($FUNCTION "${UNUSED_OPTIONS[@]}" "$URL")
        if test "$LINK_ONLY"; then
            echo $FILE_URL
        else 
            if can_module_continue_downloads "$MODULE"; then
                debug "download continuation is enabled for module $MODULE"
                CURL="curl -C -" 
            else
                CURL="curl"
            fi
            FILENAME=$(basename "$FILE_URL" | sed "s/?.*$//" | recode html..) &&
            $CURL --globoff -o "$FILENAME" "$FILE_URL" &&
            echo $FILENAME || 
            { debug "error downloading: $URL"; RETVAL=$DERROR; continue; }
        fi
        if test "$TYPE" = "file" -a "$MARK_DOWNLOADED"; then 
            sed -i "s|^[[:space:]]*\($URL\)[[:space:]]*$|#\1|" "$ITEM" && 
            debug "link marked as downloaded in input file: $ITEM" ||
            debug "error marking link as downloaded in input file: $ITEM"
        fi 
    done
done

exit $RETVAL
