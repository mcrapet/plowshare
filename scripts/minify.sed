#!/bin/sed -nf
# Basic minification of bash sources.
# Actions:
# - delete empty lines
# - delete comment lines
# - shrink (but preserve) indentation (4n spaces => n spaces)
1{
  /^#!/p
}
/^\s*$/d
/^\s*#/!{
  :a
  s/^\(#*\)\s\{4\}/\1#/
  ta
  :b
  s/^\(\s*\)#/\1 /
  tb
  p
}
