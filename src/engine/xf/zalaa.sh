#!/bin/bash
#
# zalaa callbacks
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

# Clone of uploadc, maybe will mrege it with generic if more such sites discovered

xfcb_zalaa_dl_parse_form2() {
    xfcb_generic_dl_parse_form2 "$1" 'frmdownload' '' '' '' '' '' '' '' '' \
        'ipcount_val'
}

xfcb_zalaa_dl_commit_step2() {
    local -r COOKIE_FILE=$1
    #local -r FORM_ACTION=$2
    local -r FORM_DATA=$3
    #local -r FORM_CAPTCHA=$4

    local JS URL PAGE FILE_URL EXTRA FILE_NAME

    FILE_NAME=$(parse . '=\(.*\)$' <<< "$FORM_DATA") || return

    PAGE=$(xfcb_generic_dl_commit_step2 "$@") || return

    URL=$(parse_attr "/download-[[:alnum:]]\{12\}.html" 'href' <<< "$PAGE") || return

    # Required to download file
    EXTRA="MODULE_XFILESHARING_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=( -e \"$URL\" )"

    PAGE=$(curl -i -e "$URL" -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return

    detect_javascript || return

    log_debug 'Decrypting final link...'

    JS=$(parse "^<script type='text/javascript'>eval(function(p,a,c,k,e,d)" ">\(.*\)$" <<< "$PAGE") || return

    JS=$(xfcb_unpack_js "$JS") || return

    FILE_URL=$(parse 'document.location.href' "document.location.href='\(.*\)'" <<< "$JS") || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
    echo "$EXTRA"
}
