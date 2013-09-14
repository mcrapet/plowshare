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

# Engine initialisation. No subshell.
# $1: plowshare engine directory
xfilesharing_init() {
    ENGINE_DIR=$1
    source "$1/xf/module.sh"
    source "$1/xf/generic.sh"
}

# Check if we accept to kind of url. No subshell.
# This is used by plowdown and plowprobe.
# $1: caller (plowdown, plowup, ...)
# $2: URL to probe
# $?: 0 for success
xfilesharing_probe_module() {
    local -r NAME=$1
    local -r URL=$2
    local -i RET=$ERR_NOMODULE

    if [[ $URL =~ http://(www\.)?filerio\.in/[[:alnum:]]{12} ]]; then
        SUBMODULE=filerio
        RET=0
    elif [[ $URL =~ https?://(www\.)?180upload\.com/ ]]; then
        SUBMODULE=180upload
        RET=0
    fi

    if [ $RET -eq 0 ]; then
        source "$ENGINE_DIR/xf/$SUBMODULE.sh"
        log_debug "submodule: '$SUBMODULE'"
    fi

    return $RET
}

# An engine can eventually provides several modules
# $1: URL to probe
# stdout: module name
xfilesharing_get_module() {
    test "$SUBMODULE" || return $ERR_NOMODULE
    echo 'xfilesharing'
}

# Availables wrappers:
# - parse_error
# - parse_form1
# - parse_form2
# - parse_final_link
# - commit_step1
# - commit_step2

# Check and parse any errors
# $1: page
xfilesharing_parse_error() {
    local -u VAR=${SUBMODULE}_FUNCS
    FUNC=${!VAR[parse_error]}
    test "$FUNC" || FUNC=${GENERIC_FUNCS[parse_error]}
    $FUNC "$@"
}

xfilesharing_parse_form1() {
    local -u VAR=${SUBMODULE}_FUNCS
    FUNC=${!VAR[parse_form1]}
    test "$FUNC" || FUNC=${GENERIC_FUNCS[parse_form1]}
    $FUNC "$@"
}

# Parse second form
# $1: (X)HTML page data
# $2: (optional) form name
# stdout: form_html and form inputs
xfilesharing_parse_form2() {
    local -u VAR=${SUBMODULE}_FUNCS
    FUNC=${!VAR[parse_form2]}
    test "$FUNC" || FUNC=${GENERIC_FUNCS[parse_form2]}
    $FUNC "$@"
}

# Parse final link
# $1: (X)HTML page data
# $2: (optional) file name
# stdout: final download link
xfilesharing_parse_final_link() {
    local -u VAR=${SUBMODULE}_FUNCS
    FUNC=${!VAR[parse_final_link]}
    test "$FUNC" || FUNC=${GENERIC_FUNCS[parse_final_link]}
    $FUNC "$@"
}

xfilesharing_commit_step1() {
    local -u VAR=${SUBMODULE}_FUNCS
    FUNC=${!VAR[commit_step1]}
    test "$FUNC" || FUNC=${GENERIC_FUNCS[commit_step1]}
    $FUNC "$@"
}

xfilesharing_commit_step2() {
    local -u VAR=${SUBMODULE}_FUNCS
    FUNC=${!VAR[commit_step2]}
    test "$FUNC" || FUNC=${GENERIC_FUNCS[commit_step2]}
    $FUNC "$@"
}
