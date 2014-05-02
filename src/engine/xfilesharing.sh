#!/bin/bash
#
# xfilesharing engine
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

# Engine options
ENGINE_XFILESHARING_OPTIONS=
ENGINE_XFILESHARING_FLAGS=

# Generic callback functions list
declare -ra XFCB_FUNCTIONS=(
login
handle_captcha
check_antiddos
unpack_js
dl_parse_error
dl_parse_form1
dl_parse_form2
dl_parse_final_link
dl_commit_step1
dl_commit_step2
dl_parse_streaming
dl_parse_imagehosting
dl_parse_countdown
ul_get_space_data
ul_get_folder_data
ul_create_folder
ul_get_file_id
ul_parse_data
ul_commit
ul_parse_result
ul_commit_result
ul_handle_state
ul_parse_del_code
ul_parse_file_id
ul_move_file
ul_edit_file
ul_set_flag_premium
ul_set_flag_public
ul_generate_links
ul_remote_queue_test
ul_remote_queue_check
ul_remote_queue_add
ul_remote_queue_del
ul_get_file_code
pr_parse_file_name
pr_parse_file_size
ls_parse_links
ls_parse_names
ls_parse_last_page
ls_parse_folders)

# Generic submodule options list
declare -ra OPTS_VAR_SUBMODULE=(
DOWNLOAD_OPTIONS
DOWNLOAD_RESUME
DOWNLOAD_FINAL_LINK_NEEDS_COOKIE
DOWNLOAD_FINAL_LINK_NEEDS_EXTRA
DOWNLOAD_SUCCESSIVE_INTERVAL
UPLOAD_OPTIONS
UPLOAD_REMOTE_SUPPORT
DELETE_OPTIONS
PROBE_OPTIONS
LIST_OPTIONS
LIST_HAS_SUBFOLDERS)

# Globals
declare XFILESHARING_ENGINE_DIR
declare XFILESHARING_SUBMODULE

declare XFILESHARING_URL_UPLOAD

# Get module list for xfilesharing engine
# Note: use global variable ENGINE_DIR
#
# stdout: return module list (one name per line)
xfilesharing_grep_list_modules() {
    local -r CONFIG="$XFILESHARING_ENGINE_DIR/xf/config"

    if [ ! -f "$CONFIG" ]; then
        log_error "Can't find xfilesharing config file"
        return $ERR_SYSTEM
    fi

    sed -ne "/^[^#]/{/.*/s/^\([^[:space:],]*\).*/\1/p}" "$CONFIG"
}

# Static function. Get module property
# $1: module name
# $2: property name to get. Accepted value(s): URL_UPLOAD
# stdout: requested property
xfilesharing_get_submodule_property() {
    local -r CONFIG="$XFILESHARING_ENGINE_DIR/xf/config"

    if [ ! -f "$CONFIG" ]; then
        log_error "Can't find xfilesharing config file"
        return $ERR_SYSTEM
    fi

    while IFS=',' read -r MODULE URL_REGEX URL_UPLOAD_PROP; do
        if [ "$MODULE" = "$1" ]; then
            case "$2" in
                'URL_UPLOAD')
                    echo "$URL_UPLOAD_PROP"
                    ;;
            esac
            return 0
        fi
    done < "$CONFIG"
    return $ERR_NOMODULE
}

# Static function. Get module name by URL
# $1: URL
# stdout: module name
xfilesharing_get_submodule() {
    local -r CONFIG="$XFILESHARING_ENGINE_DIR/xf/config"

    if [ ! -f "$CONFIG" ]; then
        log_error "Can't find xfilesharing config file"
        return $ERR_SYSTEM
    fi

    while IFS=',' read -r MODULE URL_REGEX URL_UPLOAD; do
        if match "$URL_REGEX" "$1"; then
            echo "$MODULE"
            return 0
        fi
    done < "$CONFIG"
    return $ERR_NOMODULE
}

# Engine initialisation. No subshell.
# $1: plowshare engine directory
xfilesharing_init() {
    XFILESHARING_ENGINE_DIR=$1

    source "$XFILESHARING_ENGINE_DIR/xf/module.sh"
    source "$XFILESHARING_ENGINE_DIR/xf/module_options.sh"
    source "$XFILESHARING_ENGINE_DIR/xf/generic.sh"

    #XF_MODULES=$(xfilesharing_grep_list_modules) || return
    #
    #for XF_MODULE in $XF_MODULES; do
    #    if [ -f "$XFILESHARING_ENGINE_DIR/xf/$XF_MODULE.sh" ]; then
    #        source "$XFILESHARING_ENGINE_DIR/xf/$XF_MODULE.sh"
    #    fi
    #done
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
        XFILESHARING_SUBMODULE=$(xfilesharing_get_submodule "$MODULE_DATA") || RET=$ERR_NOMODULE
    elif [ "$NAME" = 'plowup' ]; then
        XFILESHARING_URL_UPLOAD=$(xfilesharing_get_submodule_property "$MODULE_DATA" \
            'URL_UPLOAD' ) || RET=$ERR_NOMODULE
        XFILESHARING_SUBMODULE=$MODULE_DATA
    fi

    if [ $RET -eq 0 ]; then
        if [ -f "$XFILESHARING_ENGINE_DIR/xf/$XFILESHARING_SUBMODULE.sh" ]; then
            source "$XFILESHARING_ENGINE_DIR/xf/$XFILESHARING_SUBMODULE.sh"
            log_debug "submodule: '$XFILESHARING_SUBMODULE' (custom)"
        else
            log_debug "submodule: '$XFILESHARING_SUBMODULE' (generic)"
        fi

        case "$NAME" in
            'plowdown')
                eval "xfilesharing_${XFILESHARING_SUBMODULE}_download(){ xfilesharing_module_download \"\$@\"; }"
                ;;
            'plowlist')
                eval "xfilesharing_${XFILESHARING_SUBMODULE}_list(){ xfilesharing_module_list \"\$@\"; }"
                ;;
            'plowdel')
                eval "xfilesharing_${XFILESHARING_SUBMODULE}_delete(){ xfilesharing_module_delete \"\$@\"; }"
                ;;
            'plowprobe')
                eval "xfilesharing_${XFILESHARING_SUBMODULE}_probe(){ xfilesharing_module_probe \"\$@\"; }"
                ;;
            'plowup')
                eval "xfilesharing_${XFILESHARING_SUBMODULE}_upload(){ xfilesharing_module_upload \"\$@\"; }"
                ;;
        esac

        for FUNCTION_NAME in "${XFCB_FUNCTIONS[@]}"; do
            if ! declare -f "xfcb_${XFILESHARING_SUBMODULE}_${FUNCTION_NAME}" >/dev/null; then
                eval "xfcb_${XFILESHARING_SUBMODULE}_${FUNCTION_NAME}(){
                    xfcb_generic_${FUNCTION_NAME} \"\$@\"
                }"
            fi

            eval "xfcb_${FUNCTION_NAME}() { xfcb_${XFILESHARING_SUBMODULE}_${FUNCTION_NAME} \"\$@\"; }"
        done

        for OPTION_NAME in "${OPTS_VAR_SUBMODULE[@]}"; do
            local -u SUBMODULE_OPTION="MODULE_XFILESHARING_${XFILESHARING_SUBMODULE}_${OPTION_NAME}"

            if [ -n "${!SUBMODULE_OPTION}" ]; then
                case $OPTION_NAME in
                    *_OPTIONS)
                        eval "$SUBMODULE_OPTION=\"\$MODULE_XFILESHARING_GENERIC_${OPTION_NAME}${!SUBMODULE_OPTION}\""
                        ;;
                    *)
                        eval "$SUBMODULE_OPTION=\"${!SUBMODULE_OPTION}\""
                        ;;
                esac
            else
                eval "$SUBMODULE_OPTION=\"\$MODULE_XFILESHARING_GENERIC_${OPTION_NAME}\""
            fi
        done
    fi

    return $RET
}

# An engine can eventually provides several modules
# $1: URL to probe
# stdout: module name
xfilesharing_get_module() {
    test "$XFILESHARING_SUBMODULE" || return $ERR_NOMODULE
    echo "xfilesharing:$XFILESHARING_SUBMODULE"
}

# Look for a configuration module variable
# $1: option family name (string, example:UPLOAD)
# stdout: options list (one per line)
xfilesharing_get_all_modules_options() {
    local -ur VAR_OPTIONS_GENERIC="MODULE_XFILESHARING_GENERIC_${1}_OPTIONS"

    strip_and_drop_empty_lines "${!VAR_OPTIONS_GENERIC}"

    while read -r; do
        for OPTION_NAME in "${OPTS_VAR_SUBMODULE[@]}"; do
            local -u VAR="MODULE_XFILESHARING_${REPLY}_${OPTION_NAME}"
            if [ -n "${!VAR}" ]; then
                strip_and_drop_empty_lines "${!VAR}"
            fi
        done
    done < <(xfilesharing_grep_list_modules)
}

# Look for a configuration module variable
# $1: option family name (string, example:UPLOAD)
# stdout: options list (one per line)
xfilesharing_get_core_options() {
    local -ur VAR_OPTIONS="ENGINE_XFILESHARING_${1}_OPTIONS"

    strip_and_drop_empty_lines "${!VAR_OPTIONS}"
}
