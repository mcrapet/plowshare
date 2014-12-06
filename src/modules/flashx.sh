# Plowshare flashx.tv module
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

MODULE_FLASHX_REGEXP_URL='http://\(www\.\)\?flashx\.tv/'

MODULE_FLASHX_DOWNLOAD_OPTIONS=""
MODULE_FLASHX_DOWNLOAD_RESUME=yes
MODULE_FLASHX_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FLASHX_DOWNLOAD_SUCCESSIVE_INTERVAL=
MODULE_FLASHX_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=

MODULE_FLASHX_PROBE_OPTIONS=""

# Output a flashx file download URL
# $1: cookie file
# $2: flashx url
# stdout: real file download link
flashx_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.flashx.tv'
    local PAGE VIDEO_ID SMIL_URL LINK_BASE LINK_ID FILE_NAME FILE_URL

    detect_javascript || return

    VIDEO_ID=$(parse . '[/?]\([a-z0-9]*\)' <<< "$URL")
    log_debug "Video ID: $VIDEO_ID"

    PAGE=$(curl "$BASE_URL/$VIDEO_ID") || return

    # pattern still valid?
    if match 'Video not found, deleted, abused or wrong link\|Video not found, deleted or abused, sorry!' \
       "$PAGE"; then
           return $ERR_LINK_DEAD
    fi

    if match '<b>ERROR - 404 - FILE NOT FOUND</b>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(parse_form_input_by_name 'fname' <<< "$PAGE") || return
    log_debug "file name: $FILE_NAME"

    # using embedded video page is easier
    PAGE=$(curl "$BASE_URL/embed-$VIDEO_ID.html") || return
    JS=$(grep_script_by_order "$PAGE" -2) || return
    JS=${JS#*>}
    JS=${JS%<*}

    SMIL_URL=$(javascript <<< "empty = function(f) {};
      setup = function(opts) {
        print(opts.sources[0].file);
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
      $JS") || return
    log_debug smil url: "$SMIL_URL"

    PAGE=$(curl "$SMIL_URL") || return
    LINK_BASE=$(parse base '://\([^:/]*\)' <<< "$PAGE") || return
    # first link is usually the one with the best quality
    LINK_ID=$(parse 'video src' '?h=\([a-z0-9]*\)' <<< "$PAGE") || return
    FILE_URL="http://$LINK_BASE/$LINK_ID/video.mp4"

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: flashx.tv url
# $3: requested capability list
# stdout: 1 capability per line
flashx_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local -r BASE_URL='http://www.flashx.tv'
    local PAGE VIDEO_ID REQ_OUT FILE_NAME

    VIDEO_ID=$(parse . '[/?]\([a-z0-9]*\)' <<< "$URL")
    PAGE=$(curl "$BASE_URL/$VIDEO_ID") || return

    # pattern still valid?
    if match 'Video not found, deleted, abused or wrong link\|Video not found, deleted or abused, sorry!' \
       "$PAGE"; then
           return $ERR_LINK_DEAD
    fi

    if match '<b>ERROR - 404 - FILE NOT FOUND</b>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse_form_input_by_name 'fname' <<< "$PAGE") && \
            echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    echo $REQ_OUT
}
