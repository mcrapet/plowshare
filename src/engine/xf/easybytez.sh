#!/bin/bash
#
# easybytez callbacks
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

xfcb_easybytez_login() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local -r AUTH=$3
    local LOGIN_URL=$4
    local LOGIN_DATA LOGIN_RESULT STATUS NAME

    [ -z "$LOGIN_URL" ] && LOGIN_URL="$BASE_URL/"

    LOGIN_DATA='op=login2&login=$USER&password=$PASSWORD&redirect='
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA$BASE_URL/?op=my_account" \
        "$LOGIN_URL" -b 'lang=english') || return

    # If successful, entries are added into cookie file: login (optional) and xfss (or xfsts)
    STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
    if [ -z "$STATUS" ]; then
        STATUS=$(parse_cookie_quiet 'xfsts' < "$COOKIE_FILE")
        [ -n "$STATUS" ] && log_debug 'xfsts login cookie'
    fi

    if [ -z "$STATUS" ]; then
        return $ERR_LOGIN_FAILED
    fi

    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -z "$NAME" ]; then
        log_debug 'No login information in cookie.'
    else
        log_debug "Successfully logged in as $NAME."
    fi

    return 0
}

xfcb_easybytez_dl_parse_error() {
    local PAGE=$1

    if  match 'File not available' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    xfcb_generic_dl_parse_error "$@"
}
