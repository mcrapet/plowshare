#!/bin/bash
#
# Template module for downshare.
#
LIBDIR=$(dirname "$(readlink -f "$(type -P $0)")")
source $LIBDIR/lib.sh

PLOWSHARE_MYMODULE="http://\(www\.\)\?server.com/files/"

# Output a mymodule file download URL
#
# $1: A mymodule URL
# $2/$3: User/password (optional)
mymodule_download() {
    URL=$1
    USER=$2
    PASSWORD=$3
    # Your code here
    # echo $FILE_URL    
}

# Upload a file to mymodule
#
# $1: File path
# $2: Description
# $3/$4: User/password (optional)
#
mymodule_upload() {
    FILE=$1
    DESCRIPTION=$2    
    USER=$3
    PASSWORD=$4
    # echo $FILE_URL         
}
