#!/bin/bash
#
# tinypic callbacks
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

declare -gA TINYPIC_FUNCS
TINYPIC_FUNCS['dl_parse_form2']='tinypic_dl_parse_form2'

tinypic_dl_parse_form2() {
    local PAGE=$1

    # Remove excess form inside main form
    # password input is placed below that form
    PAGE="${PAGE//<\/form>/}"

    xfilesharing_dl_parse_form2_generic "$PAGE"
}
