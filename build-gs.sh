#!/bin/bash
#
# build-gs.sh -- builds a self-contained Ghostscript for the DesignJet 500 filter.
#
# Why: under cupsd, filters run in Apple's sandbox, which cannot read or
# execute anything in /opt/local, /opt/homebrew or /usr/local. The filter
# therefore ships its own static Ghostscript under /Library/Printers.
#
# Result: vendor/gs/bin/gs  (static, links only macOS system libraries,
#         devices: cdnj500 + pdfwrite)
#
#   ./build-gs.sh                      download + build (~5 min on M-series)
#   GS_BUILD_DIR=/path ./build-gs.sh   reuse an existing download/build dir

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GS_VERSION=10.07.0
GS_TAG=gs10070
GS_TARBALL=ghostscript-$GS_VERSION.tar.xz
GS_URL=https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/$GS_TAG/$GS_TARBALL
# SHA-512 of the release tarball, from the SHA512SUMS file published with the
# gs10070 GitHub release (Artifex publishes SHA-512 only).
GS_SHA512=1c2a14951223c975a53bd9767c28bd3a6e420c385a5e0d7a60a5ff5b091bc027929c815bf57cddf97611e8d265ece1c219321737f2cabb5646685c6e8cdb85c9

BUILD_DIR=${GS_BUILD_DIR:-$HERE/build/ghostscript}
OUT_DIR=$HERE/vendor/gs/bin
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

mkdir -p "$BUILD_DIR" "$OUT_DIR"
cd "$BUILD_DIR"

# --- download + verify -----------------------------------------------------
if [ ! -f "$GS_TARBALL" ]; then
    echo "downloading $GS_URL"
    curl -fsSL -o "$GS_TARBALL.part" "$GS_URL"
    mv "$GS_TARBALL.part" "$GS_TARBALL"
fi
actual=$(shasum -a 512 "$GS_TARBALL" | awk '{print $1}')
if [ "$actual" != "$GS_SHA512" ]; then
    echo "checksum mismatch for $GS_TARBALL" >&2
    echo "  expected $GS_SHA512" >&2
    echo "  actual   $actual" >&2
    exit 1
fi
echo "checksum OK"

SRC=$BUILD_DIR/ghostscript-$GS_VERSION
if [ ! -d "$SRC" ]; then
    tar xJf "$GS_TARBALL"
fi
cd "$SRC"

# --- configure ---------------------------------------------------------------
# Everything optional is off so the binary has no dependency outside macOS.
# Bundled third-party sources (zlib, libpng, jpeg, freetype, lcms2, ...) are
# used instead of anything found on the build machine.
if [ ! -f Makefile ] || ! grep -q 'cdnj500' Makefile; then
    ./configure \
        --disable-fontconfig \
        --disable-dbus \
        --disable-cups \
        --without-pdftoraster \
        --without-tesseract \
        --without-libidn \
        --without-libpaper \
        --without-x \
        --disable-gtk \
        --with-drivers=cdnj500,pdfwrite \
        > configure.log 2>&1 || { tail -30 configure.log >&2; exit 1; }
fi

# --- build -------------------------------------------------------------------
echo "building with $JOBS jobs ..."
make -j"$JOBS" > make.log 2>&1 || { tail -40 make.log >&2; exit 1; }

# --- verify ------------------------------------------------------------------
GS_BIN=$SRC/bin/gs
help_text=$("$GS_BIN" -h 2>/dev/null)
for dev in cdnj500 pdfwrite; do
    grep -qw "$dev" <<<"$help_text" || { echo "device $dev missing from build" >&2; exit 1; }
done

if otool -L "$GS_BIN" | grep -E '^\s*/(opt|usr/local)/' ; then
    echo "built gs links against non-system libraries (see above); refusing" >&2
    exit 1
fi

install -m 755 "$GS_BIN" "$OUT_DIR/gs"
codesign --force --sign - "$OUT_DIR/gs" >/dev/null 2>&1 || true
echo "wrote $OUT_DIR/gs ($(du -h "$OUT_DIR/gs" | cut -f1))"
"$OUT_DIR/gs" --version
