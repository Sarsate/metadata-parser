#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Retry with \"sudo ./setup.sh\"."
  exit 0
fi

TOP_DIR=$(cd $(dirname "$0") && pwd)

apt-get install python-mutagen vorbis-tools

cd $TOP_DIR/python/metadata_parser/
python setup.py install
cd $TOP_DIR
