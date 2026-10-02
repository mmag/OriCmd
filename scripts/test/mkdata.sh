#!/bin/zsh
# Recreates build/testdata (the only place automated test runs may touch).
cd "$(dirname $0)/../.."
# A test may leave a locked file behind (it would stop rm).
[ -d build/testdata ] && chflags -R nouchg build/testdata
rm -rf build/testdata
mkdir -p build/testdata/left/{alpha,beta,gamma.app/Contents} build/testdata/right
cd build/testdata/left
for n in readme.txt notes.md data.csv image.png script.sh archive.zip file10.txt file2.txt Makefile .hidden; do
  head -c $((RANDOM*3)) /dev/urandom > "$n"
done
echo "hello from alpha" > alpha/inside.txt
mkdir -p beta/deep/deeper && head -c 200000 /dev/urandom > beta/deep/deeper/blob.bin
sips -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns --out picture.png >/dev/null 2>&1
printf 'Привет, мир! Это текст в кодировке Windows-1251.\nВторая строка.\n' | iconv -f UTF-8 -t CP1251 > cp1251.txt
mkdir -p many && for i in $(seq 1 120); do touch "many/document-$i.txt"; done && mkdir -p many/subfolder
zip -qr archive-test.zip alpha beta notes.md
tar -czf bundle.tar.gz alpha many
