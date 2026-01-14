#!/bin/sh
set -eu

log()   { printf "\033[1;34m▶ %s\033[0m\n" "$*"; }
ok()    { printf "  \033[1;32m✓ %s\033[0m\n" "$*"; }
die()   { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/Builds"
OUT="$ROOT/Libraries"

ARCHS="x86_64 arm64"
LIBS_OPENSSL="libssl.a libcrypto.a"
LIBS_SSH="libssh2.a"

rm -rf "$BUILD"
mkdir -p "$BUILD" "$OUT/lib" "$OUT/include/openssl" "$OUT/include/libssh2"

cd "$ROOT/iSSH2"

for ARCH in $ARCHS; do
  log "Building for $ARCH"

  ARCH_DIR="$BUILD/$ARCH"
  mkdir -p "$ARCH_DIR"

  ./iSSH2.sh \
    --archs="$ARCH" \
    --platform=macosx \
    --min-version=10.15 \
    --output="$ARCH_DIR" \
    >"$ARCH_DIR/build.log" 2>&1 \
    || die "Build failed for $ARCH (see $ARCH_DIR/build.log)"

  ok "OpenSSL + libssh2"
done

log "Creating universal libraries"

TMP="$BUILD/universal"
mkdir -p "$TMP"

for LIB in $LIBS_OPENSSL; do
  lipo -create \
    "$BUILD/x86_64/openssl_macosx/lib/$LIB" \
    "$BUILD/arm64/openssl_macosx/lib/$LIB" \
    -output "$TMP/$LIB"
  ok "$LIB"
done

for LIB in $LIBS_SSH; do
  lipo -create \
    "$BUILD/x86_64/libssh2_macosx/lib/$LIB" \
    "$BUILD/arm64/libssh2_macosx/lib/$LIB" \
    -output "$TMP/$LIB"
  ok "$LIB"
done

cp "$TMP/"*.a "$OUT/lib"
cp "$BUILD/arm64/openssl_macosx/include/openssl/"*.h "$OUT/include/openssl"
cp "$BUILD/arm64/libssh2_macosx/include/"*.h "$OUT/include/libssh2"

log "Done"
