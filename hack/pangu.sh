#!/bin/bash

FILE=$1

if [ ! -f "$FILE" ]; then
	echo "Usage: ${BASH_SOURCE[0]} '/path/to/file'"
	exit 1
fi

echo "Format $FILE"

which pangu > /dev/null

EXISTING=$?

if [ "$EXISTING" != "0" ]; then
    echo "Install pangu-cli by 'npm install -g pangu-cli'"
else
    pangu "$FILE" "$FILE"
fi

