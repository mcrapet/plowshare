#!/bin/sh
set -e
PROJECT=$(basename "$PWD" | sed "s/-[0-9.-]*//")
TRUNK="https://$PROJECT.googlecode.com/svn/trunk/"
TAGS_URL="https://$PROJECT.googlecode.com/svn/tags/"
AUTHFILE=".googlecode-auth"
VERSION=$(cat CHANGELOG | head -n1 | sed "s/^.*(\(.*\)).*$/\1/")
LOG="$1"
DIRECTORY=$PROJECT-$VERSION

IFS=":" read USERNAME PASSWORD < "$AUTHFILE"
FILE=$DIRECTORY.tgz

test $# -ne 0 || { echo "Usage: $0 LOG"; exit 1; }

rm -rf $DIRECTORY
svn export $TRUNK $DIRECTORY --username $USERNAME --force
tar -zcf $FILE $DIRECTORY
echo "tgz: $FILE"

expect << EOF 
    spawn googlecode-upload.py -s "$LOG" -p $PROJECT -u $USERNAME $FILE
    expect "Password:"
    send "$PASSWORD\r"
    expect
EOF

TAG="RELEASE-$VERSION"
echo "creating tag: $TAG"
svn copy -m "$LOG" $TRUNK $TAGS_URL/$TAG
