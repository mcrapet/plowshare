#!/bin/bash
#
# xfilesharing engine
# Copyright (c) 2013 Plowshare team
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

# Globals
declare ENGINE_DIR
declare SUBMODULE

declare URL_UPLOAD

# Get module list for xfilesharing engine
# Note: use global variable ENGINE_DIR
#
# stdout: return module list (one name per line)
grep_list_xfilesharing_modules() {
    local -r CONFIG="$ENGINE_DIR/xf/config"

    if [ ! -f "$CONFIG" ]; then
        stderr "can't find xfilesharing config file"
        return $ERR_SYSTEM
    fi

    sed -ne "/^[^#]/{/.*/s/^\([^[:space:],]*\).*/\1/p}" \
        "$CONFIG"
}

# Static function. Get module property
# $1: module name
# $2: property name to get
# stdout: requested property
xfilesharing_get_submodule_property() {
    local -r CONFIG="$ENGINE_DIR/xf/config"

    if [ ! -f "$CONFIG" ]; then
        stderr "can't find xfilesharing config file"
        return $ERR_SYSTEM
    fi

    while IFS=',' read -r MODULE URL_REGEX \
        URL_UPLOAD_PROP; do
        if [ "$MODULE" = "$1" ]; then
            case "$2" in
            'URL_UPLOAD')
                echo "$URL_UPLOAD_PROP"
                ;;
            esac

            unset IFS
            return 0
        fi
    done < "$CONFIG"
    unset IFS

    return 1
}

# Static function. Get module name by URL
# $1: URL
# stdout: module name
xfilesharing_get_submodule() {
    local -r CONFIG="$ENGINE_DIR/xf/config"

    if [ ! -f "$CONFIG" ]; then
        stderr "can't find xfilesharing config file"
        return $ERR_SYSTEM
    fi

    while IFS=',' read -r MODULE URL_REGEX \
        URL_UPLOAD; do
        if match "$URL_REGEX" "$1"; then
            echo "$MODULE"

            unset IFS
            return 0
        fi
    done < "$CONFIG"
    unset IFS

    return 1
}

# Engine initialisation. No subshell.
# $1: plowshare engine directory
xfilesharing_init() {
    ENGINE_DIR=$1

    source "$ENGINE_DIR/xf/module.sh"
    source "$ENGINE_DIR/xf/generic.sh"

    XF_MODULES=$(grep_list_xfilesharing_modules) || return

    for XF_MODULE in $XF_MODULES; do
        if [ -f "$ENGINE_DIR/xf/$XF_MODULE.sh" ]; then
            source "$ENGINE_DIR/xf/$XF_MODULE.sh"
        fi
    done
}

# Check if we accept this kind of url. No subshell.
# This is used by plowdown and plowprobe.
# $1: caller (plowdown, plowup, ...)
# $2: URL or module to probe
# $?: 0 for success
xfilesharing_probe_module() {
    local -r NAME=$1
    local -r MODULE_DATA=$2
    local -i RET=0

    if [ "$NAME" = 'plowdown' ] || [ "$NAME" = 'plowlist' ] || [ "$NAME" = 'plowdel' ] || [ "$NAME" = 'plowprobe' ]; then
        SUBMODULE=$(xfilesharing_get_submodule "$MODULE_DATA") || RET=$ERR_NOMODULE
    elif [ "$NAME" = 'plowup' ]; then
        URL_UPLOAD=$(xfilesharing_get_submodule_property "$MODULE_DATA" 'URL_UPLOAD' ) || RET=$ERR_NOMODULE
        SUBMODULE="$MODULE_DATA"
    fi

    if [ $RET -eq 0 ]; then
        if [ -f "$ENGINE_DIR/xf/$SUBMODULE.sh" ]; then
            log_debug "submodule: '$SUBMODULE' (custom)"
        else
            log_debug "submodule: '$SUBMODULE' (generic)"
        fi

        case "$NAME" in
            'plowdown')
                eval "xfilesharing:${SUBMODULE}_download(){ xfilesharing_download \"\$@\"; }"
                ;;
            'plowlist')
                eval "xfilesharing:${SUBMODULE}_list(){ xfilesharing_list \"\$@\"; }"
                ;;
            'plowdel')
                eval "xfilesharing:${SUBMODULE}_delete(){ xfilesharing_delete \"\$@\"; }"
                ;;
            'plowprobe')
                eval "xfilesharing:${SUBMODULE}_probe(){ xfilesharing_probe \"\$@\"; }"
                ;;
            'plowup')
                eval "xfilesharing:${SUBMODULE}_upload(){ xfilesharing_upload \"\$@\"; }"
                ;;
        esac

        while read -r FUNCTION_NAME; do
            [ -z "$FUNCTION_NAME" ] && continue
            if ! declare -f "xfilesharing:${SUBMODULE}_${FUNCTION_NAME}" >/dev/null; then
                eval "xfilesharing:${SUBMODULE}_${FUNCTION_NAME}(){
                    xfilesharing_${FUNCTION_NAME}_generic \"\$@\"
                }"
            fi

            eval "xfilesharing_${FUNCTION_NAME}() { xfilesharing:${SUBMODULE}_${FUNCTION_NAME} \"\$@\"; }"
        done <<< "$XFILESHARING_FUNCTIONS"

        while read -r OPTION_NAME; do
            [ -z "$OPTION_NAME" ] && continue
            local -u SUBMODULE_OPTION="MODULE_XFILESHARING_${SUBMODULE}_${OPTION_NAME}"

            if [ -n "${!SUBMODULE_OPTION}" ]; then
                case "$OPTION_NAME" in
                    'DOWNLOAD_OPTIONS'|'UPLOAD_OPTIONS'|'DELETE_OPTIONS'|'PROBE_OPTIONS'|'LIST_OPTIONS')
                        eval "$SUBMODULE_OPTION=\"\$XFILESHARING_${OPTION_NAME}_GENERIC${!SUBMODULE_OPTION}\""
                        ;;
                    *)
                        eval "$SUBMODULE_OPTION=\"${!SUBMODULE_OPTION}\""
                        ;;
                esac
            else
                eval "$SUBMODULE_OPTION=\"\$XFILESHARING_${OPTION_NAME}_GENERIC\""
            fi
        done <<< "$XFILESHARING_OPTIONS"
    fi

    return $RET
}

# An engine can eventually provides several modules
# $1: URL to probe
# stdout: module name
xfilesharing_get_module() {
    test "$SUBMODULE" || return $ERR_NOMODULE
    echo "xfilesharing:$SUBMODULE"
}

# Look for a configuration module variable
# $1: option family name (string, example:UPLOAD)
# stdout: options list (one per line)
xfilesharing_get_all_modules_options() {
    local -ur VAR_OPTIONS="${1}_OPTIONS"
    local -ur VAR_OPTIONS_GENERIC="XFILESHARING_${VAR_OPTIONS}_GENERIC"
    local OPTIONS

    strip_and_drop_empty_lines "${!VAR_OPTIONS_GENERIC}"

    while read -r; do
        while read -r OPTION_NAME; do
            local -u VAR="MODULE_XFILESHARING_${REPLY}_${OPTION_NAME}"
            if [ -n "${!VAR}" ]; then
                strip_and_drop_empty_lines "${!VAR}"
            fi
        done <<< "$XFILESHARING_OPTIONS"
    done <<< "$(grep_list_xfilesharing_modules)"
}
