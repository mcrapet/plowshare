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

MODULE_LETITBIT_REGEXP_URL="http://\(www\.\)\?letitbit\.net/download/"
MODULE_LETITBIT_DOWNLOAD_OPTIONS=""
MODULE_LETITBIT_UPLOAD_OPTIONS=
MODULE_LETITBIT_DOWNLOAD_CONTINUE=no

# Output a letitbit.net file download URL (free download)
#
# $1: A letitbit.net URL
#
letitbit_download() {
    set -e
    eval "$(process_options letitbit "$MODULE_LETITBIT_DOWNLOAD_OPTIONS" "$@")"

    COOKIES=$(create_tempfile)
    HTML1=$(curl -c $COOKIES "$1")

    local FORM_HTML=$(grep_form_by_order "$HTML1" 4)
    local form_url=$(echo "$FORM_HTML" | parse_form_action)
    local form_md5cypt=$(echo "$FORM_HTML" | parse_form_input_by_name 'md5crypt')
    local form_uid5=$(echo "$FORM_HTML" | parse_form_input_by_name 'uid5')
    local form_uid=$(echo "$FORM_HTML" | parse_form_input_by_name 'uid')
    local form_name=$(echo "$FORM_HTML" | parse_form_input_by_name 'name')
    local form_pin=$(echo "$FORM_HTML" | parse_form_input_by_name 'pin')
    local form_realuid=$(echo "$FORM_HTML" | parse_form_input_by_name 'realuid')
    local form_realname=$(echo "$FORM_HTML" | parse_form_input_by_name 'realname')
    local form_host=$(echo "$FORM_HTML" | parse_form_input_by_name 'host')
    local form_ssserver=$(echo "$FORM_HTML" | parse_form_input_by_name 'ssserver')
    local form_sssize=$(echo "$FORM_HTML" | parse_form_input_by_name 'sssize')
    local form_optiondir=$(echo "$FORM_HTML" | parse_form_input_by_name 'optiondir')
    local form_pin_wm=$(echo "$FORM_HTML" | parse_form_input_by_name 'pin_wm')

    HTML2=$(curl -b $COOKIES --data "md5crypt=${form_md5cypt}&uid5=${form_uid5}&uid=${form_uid}&name=${form_name}&pin=${form_pin}&realuid=${form_realuid}&realname=${form_realname}&host=${form_host}&ssserver=${form_ssserver}&sssize=${form_sssize}&optiondir=${form_optiondir}&pin_wm=${form_pin_wm}" \
            "$form_url") || return 1

    FORM_HTML=$(grep_form_by_id "$HTML2" "dvifree")
    form_url=$(echo "$FORM_HTML" | parse_form_action)
    form_uid2=$(echo "$FORM_HTML" | parse_form_input_by_name 'uid2')
    form_md5cypt=$(echo "$FORM_HTML" | parse_form_input_by_name 'md5crypt')
    form_uid5=$(echo "$FORM_HTML" | parse_form_input_by_name 'uid5')
    form_uid=$(echo "$FORM_HTML" | parse_form_input_by_name 'uid')
    form_name=$(echo "$FORM_HTML" | parse_form_input_by_name 'name')
    form_pin=$(echo "$FORM_HTML" | parse_form_input_by_name 'pin')
    form_realuid=$(echo "$FORM_HTML" | parse_form_input_by_name 'realuid')
    form_realname=$(echo "$FORM_HTML" | parse_form_input_by_name 'realname')
    form_host=$(echo "$FORM_HTML" | parse_form_input_by_name 'host')
    form_ssserver=$(echo "$FORM_HTML" | parse_form_input_by_name 'ssserver')
    form_sssize=$(echo "$FORM_HTML" | parse_form_input_by_name 'sssize')
    form_optiondir=$(echo "$FORM_HTML" | parse_form_input_by_name 'optiondir')
    form_pin_wm=$(echo "$FORM_HTML" | parse_form_input_by_name 'pin_wm')

    # Get captcha
    CAPTCHA_URL=$(echo "$FORM_HTML" | parse_attr 'img src' 'src')
    log_debug "captcha URL: $CAPTCHA_URL"

    # OCR captcha and show ascii image to stderr simultaneously
    CAPTCHA=$(curl -b $COOKIES "$CAPTCHA_URL" | convert - +matte gif:- |
        show_image_and_tee | ocr alnum | sed "s/[^a-zA-Z0-9]//g") ||
        { log_error "error running OCR"; return 1; }

    log_debug "Decoded captcha: $CAPTCHA"
    test "${#CAPTCHA}" -ne 6 && \
        log_debug "Captcha length invalid"

    HTML3=$(curl -b $COOKIES --data "cap=${CAPTCHA}&uid2=${form_uid2}&md5crypt=${form_md5cypt}&uid5=${form_uid5}&uid=${form_uid}&name=${form_name}&pin=${form_pin}&realuid=${form_realuid}&realname=${form_realname}&host=${form_host}&ssserver=${form_ssserver}&sssize=${form_sssize}&optiondir=${form_optiondir}&pin_wm=${form_pin_wm}" \
            "$form_url") || return 1

    # TODO: finish it..
    #echo "$HTML3" >/tmp/c
    # wait counter is looping ???

    rm -f $COOKIES
    return 1
}
