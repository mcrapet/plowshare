#!/bin/bash
#
# Template module <mymodule> for plowshare
#
MODULE_MYMODULE_REGEXP_URL="http://\(www\.\)\?server.com/files/"

# Output a <mymodule> file download URL
#
# $1: A mymodule URL
# $2/$3: User/password (optional)
#
mymodule_download() {
    URL=$1
    USER=$2
    PASSWORD=$3
    #
    # Your code here
    #
    # echo $FILE_URL    
}

# Upload a file to <mymodule> and output generated URL
#
# $1: File path
# $2/$3: User/password (optional)
# $4: Description (optional)
#
mymodule_upload() {
    FILE=$1
    USER=$2
    PASSWORD=$3
    DESCRIPTION=$4
    #
    # Your code here
    #    
    # echo $URL         
}
