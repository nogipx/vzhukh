#!/usr/bin/env bash
# Builds libtun2socks.so for Android arm64 and x86_64.
#
# Prerequisites:
#   - Go 1.21+
#   - Android NDK in $ANDROID_NDK_HOME (or detected via $ANDROID_HOME)
#   - gomobile or manual CGO cross-compile setup
#
# Usage:
#   ./scripts/build_native.sh
#
# Output:
#   android/app/src/main/jniLibs/arm64-v8a/libtun2socks.so
#   android/app/src/main/jniLibs/x86_64/libtun2socks.so

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GO_SRC="$ROOT/go/tun2socks"

NDK="${ANDROID_NDK_HOME:-${ANDROID_HOME:-}/ndk/$(ls "${ANDROID_HOME:-}/ndk" 2>/dev/null | tail -1)}"

if [ ! -d "$NDK" ]; then
  echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME."
  exit 1
fi

echo "Using NDK: $NDK"

build_abi() {
  local abi="$1"
  local goarch="$2"
  local triple="$3"
  local clang="${NDK}/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64/bin/${triple}-clang"

  local dest="$ROOT/android/app/src/main/jniLibs/$abi"
  mkdir -p "$dest"

  echo "Building $abi …"
  cd "$GO_SRC"
  go mod download

  GOOS=android \
  GOARCH="$goarch" \
  CGO_ENABLED=1 \
  CC="$clang" \
  CGO_LDFLAGS="-llog" \
    go build \
      -buildmode=c-shared \
      -trimpath \
      -tags with_gvisor \
      -o "$dest/libtun2socks.so" \
      .

  echo "  -> $dest/libtun2socks.so"
}

# Android API 21 minimum
build_abi "arm64-v8a"  "arm64"  "aarch64-linux-android21"
build_abi "x86_64"     "amd64"  "x86_64-linux-android21"

echo ""
echo "Done. Output:"
find "$ROOT/android/app/src/main/jniLibs" -name "*.so"
