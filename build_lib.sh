#!/bin/sh

mkdir -p Libraries/lib
mkdir -p Libraries/include/libssh2
mkdir -p Libraries/include/openssl

cd ./iSSH2

./iSSH2.sh --archs=x86_64 --platform=macosx --min-version=10.12 --no-clean
mv openssl_macosx openssl_macosx_x86
mv libssh2_macosx libssh2_macosx_x86

./iSSH2.sh --archs=arm64 --platform=macosx --min-version=10.12
mv openssl_macosx openssl_macosx_arm64
mv libssh2_macosx libssh2_macosx_arm64

mkdir tmp
cd openssl_macosx_x86/lib
for f in *.a; do lipo -create "$f" "../../openssl_macosx_arm64/lib/$f" -output "../../tmp/$f"; done
cd ../../libssh2_macosx_x86/lib
for f in *.a; do lipo -create "$f" "../../libssh2_macosx_arm64/lib/$f" -output "../../tmp/$f"; done

cd ../..
cp tmp/* ../Libraries/lib
cp openssl_macosx_arm64/include/openssl/*.h ../Libraries/include/openssl
cp libssh2_macosx_arm64/include/*.h ../Libraries/include/libssh2
