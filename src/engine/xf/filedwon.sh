#!/bin/bash
#
# filedwon callbacks
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

declare -gA FILEDWON_FUNCS
FILEDWON_FUNCS['dl_parse_form2']='filedwon_dl_parse_form2'

filedwon_dl_parse_form2() {
    local PAGE=$1

    # Remove all paypal form tails from main form (which end is '</Form>')
    # password input is placed below those paypal forms
    PAGE="${PAGE//<\/form>/}"

    xfilesharing_dl_parse_form2_generic "$PAGE"
}
