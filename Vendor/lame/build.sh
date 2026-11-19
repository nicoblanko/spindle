#!/bin/sh
# Rebuilds lib/libmp3lame.a (arm64, macOS 15+) from the LAME 3.100 source.
# Source: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
# SHA-256: ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
set -e
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
cd "$work"
curl -sSfL -o lame.tar.gz https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
echo "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e  lame.tar.gz" | shasum -a 256 -c
tar xzf lame.tar.gz
cd lame-3.100
sed -i '' '/lame_init_old/d' include/libmp3lame.sym
./configure --disable-shared --enable-static --disable-frontend --disable-decoder \
    --disable-dependency-tracking --prefix="$work/out" \
    CFLAGS="-O2 -arch arm64 -mmacosx-version-min=15.0"
make -j8 && make install
cp "$work/out/lib/libmp3lame.a" "$here/lib/"
cp "$work/out/include/lame/lame.h" "$here/include/lame/"
