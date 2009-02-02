#!/bin/sh
set -e
PROJECT=$(basename "$PWD" | sed "s/-[0-9.-]*//")
URL="https://$PROJECT.googlecode.com/svn/trunk/"
AUTHFILE=".googlecode-auth"
VERSION=$(cat CHANGELOG | head -n1 | sed "s/^.*(\(.*\)).*$/\1/")
LOG="$1"
DIRECTORY=$PROJECT-$VERSION

IFS=":" read USERNAME PASSWORD < "$AUTHFILE"
FILE=$DIRECTORY.tgz
if [ ! -e $FILE ]; then
    rm -rf $DIRECTORY
    svn export $URL $DIRECTORY --username $USERNAME --force
    tar -zcf $FILE $DIRECTORY
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
echo done
