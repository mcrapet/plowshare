# Plowshare firedrive.com module
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

MODULE_FIREDRIVE_REGEXP_URL='http://\(www\.\)\?firedrive\.com/file/'

MODULE_FIREDRIVE_DOWNLOAD_OPTIONS=""
MODULE_FIREDRIVE_DOWNLOAD_RESUME=yes
MODULE_FIREDRIVE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FIREDRIVE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FIREDRIVE_PROBE_OPTIONS=""

# Output a firedrive file download URL
# $1: cookie file
# $2: firedrive url
# stdout: real file download link
firedrive_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local PAGE FORM_HTML DL_KEY FILE_URL FILE_NAME

    PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return

    # 404: This file might have been moved, replaced or deleted
    if match 'class=.removed_file_image.>' "$PAGE"; then
        return $ERR_LINK_DEAD
    # This file is private and only viewable by the owner
    elif match 'class=.private_file_image.>' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FILE_NAME=$(parse_tag 'class="external_title_left"' 'div' <<< "$PAGE") || return

    if ! match '\.pdf' "$FILE_NAME" ; then
        FORM_HTML=$(grep_form_by_id "$PAGE" 'confirm_form') || return
        DL_KEY=$(parse_form_input_by_name 'confirm' <<< "$FORM_HTML") || return

        PAGE=$(curl -b "$COOKIE_FILE" --referer "$URL" \
            --data-urlencode "confirm=$DL_KEY" "$URL") || return
    fi

    FILE_URL=$(parse_attr 'Download This File' href <<< "$PAGE") || return

    PAGE=$(curl --include -b "$COOKIE_FILE" "$FILE_URL") || return
    FILE_URL=$(grep_http_header_location <<< "$PAGE") || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: firedrive url
# $3: requested capability list
# stdout: 1 capability per line
firedrive_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_NAME FILE_SIZE

    PAGE=$(curl "$URL") || return

    # <div class="file_error_container">
    # <div class="sad_face_image"></div>

    # 404: This file might have been moved, replaced or deleted
		if match 'class=.removed_file_image.>' "$PAGE"; then
        return $ERR_LINK_DEAD
    # This file is private and only viewable by the owner
		elif match 'class=.private_file_image.>' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
		fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse 'id=.information_content.>' \
            '</b>[[:space:]]\?\([^<]\+\)' 1 <<< "$PAGE") && \
                echo "${FILE_NAME% }" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'id=.information_content.>' \
            '</b>[[:space:]]\?\([^<]\+\)' 3 <<< "$PAGE") && \
                translate_size "${FILE_SIZE% }" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
