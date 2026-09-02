#!/bin/sh

set -eu

PROJECT_DIR=${PROJECT_DIR:?PROJECT_DIR is required}
BUILD_ROOT="$PROJECT_DIR/.build/vendor/libvterm-0.3.3"
ARCHIVE="$BUILD_ROOT/libvterm-0.3.3.tar.gz"
SOURCE_ROOT="$BUILD_ROOT/source"
INSTALL_ROOT="$BUILD_ROOT/install"
OBJECT_ROOT="$BUILD_ROOT/objects"
SOURCE_URL="https://launchpad.net/libvterm/trunk/v0.3/+download/libvterm-0.3.3.tar.gz"
SOURCE_SHA256="09156f43dd2128bd347cbeebe50d9a571d32c64e0cf18d211197946aff7226e0"

mkdir -p "$BUILD_ROOT"
if [ ! -f "$ARCHIVE" ]; then
  /usr/bin/curl --fail --location --retry 3 --output "$ARCHIVE" "$SOURCE_URL"
fi

printf '%s  %s\n' "$SOURCE_SHA256" "$ARCHIVE" | /usr/bin/shasum -a 256 --check --status

if [ ! -f "$SOURCE_ROOT/Makefile" ]; then
  rm -rf "$SOURCE_ROOT"
  mkdir -p "$SOURCE_ROOT"
  /usr/bin/tar -xzf "$ARCHIVE" --strip-components=1 -C "$SOURCE_ROOT"
fi

rm -rf "$OBJECT_ROOT" "$INSTALL_ROOT"
mkdir -p "$OBJECT_ROOT" "$INSTALL_ROOT/include" "$INSTALL_ROOT/lib"

for source in "$SOURCE_ROOT"/src/*.c; do
  object="$OBJECT_ROOT/$(basename "${source%.c}").o"
  "${CC:-clang}" \
    ${CFLAGS:-} \
    -std=c99 \
    -Wall \
    -Wpedantic \
    -I"$SOURCE_ROOT/include" \
    -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -c "$source" \
    -o "$object"
done

/usr/bin/libtool -static -o "$INSTALL_ROOT/lib/libvterm.a" "$OBJECT_ROOT"/*.o
/bin/cp "$SOURCE_ROOT"/include/*.h "$INSTALL_ROOT/include/"
