#!/bin/bash

set -e

pkgconf --exists libconfuse || { echo "Error: libconfuse not found."; exit 1; }

git clone https://github.com/pengutronix/genimage.git
pushd genimage
./autogen.sh && ./configure && make -j$(nproc)
cp genimage ../genimage-bin
popd
rm -rf genimage
