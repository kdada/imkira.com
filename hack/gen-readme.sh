#!/bin/bash

ROOT_PATH=$(dirname $(bash -c "cd $(dirname ${BASH_SOURCE[0]}) >/dev/null 2>&1 && pwd"))

cd $ROOT_PATH

DIRS=$(find . -maxdepth 1 -type 'd' ! -path './.git' ! -path './.github' ! -path './hack' ! -path './assets' ! -path '.')


function clean() {
  echo -e "# Kira 的博客\n" > $ROOT_PATH/README.md
}

function write() {
  echo -e "$1" >> $ROOT_PATH/README.md
}

clean

for DIR in $DIRS
do
  CAT=$(basename $DIR)
  write "## $CAT\n"
  FILES=$(ls -r $DIR)
  echo "$CAT"
  for FILE in $FILES
  do
    echo "  $FILE"
    FILE_PATH="$DIR/$FILE"
	TITLE=$(cat $FILE_PATH | grep -oP '(?<=title: ).*$')
    write "- [$TITLE]($FILE_PATH)"
  done
  write ""
done
