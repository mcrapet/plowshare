#!/bin/sh
set -e
PROJECT=$(basename "$PWD")
URL=https://$PROJECT.googlecode.com/svn/trunk/
USERNAME=tokland
PASSWORD=$(cat .googlecode_password)
VERSION=$(cat CHANGELOG | head -n1 | sed "s/^.*(\(.*\)).*$/\1/")
LOG="$1"

FILE=$PROJECT-$VERSION.tgz
if [ ! -e $FILE ]; then
    rm -rf $PROJECT-$VERSION
    svn export $URL $PROJECT-$VERSION --username $USERNAME --force
    tar -zcf $FILE $PROJECT-$VERSION
fi

echo $FILE

if test "$LOG"; then 
    expect << EOF 
        spawn googlecode-upload.py -s "$LOG" -p $PROJECT -u $USERNAME $FILE
        expect "Password:"
        send "$PASSWORD\r"
        expect
EOF
fi
