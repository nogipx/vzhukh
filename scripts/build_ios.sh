#!/usr/bin/env bash
# Builds VzhukhTunnel.xcframework, the Go tunnel the NetworkExtension links.
#
# A static archive rather than a shared library, because iOS refuses to load
# a dylib that did not ship inside the app bundle, and an app extension is a
# worse place than most to argue with that.
#
# Prerequisites:
#   - Go 1.21+
#   - Xcode command line tools
#
# Usage:
#   ./scripts/build_ios.sh
#
# Output:
#   ios/Frameworks/VzhukhTunnel.xcframework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GO_SRC="$ROOT/go/tun2socks"

LIB_NAME="libvzhukhtunnel"
# Core, not Tunnel: the extension target is called VzhukhTunnel, and two
# modules under one name is a fight with the compiler nobody wins.
FRAMEWORK="$ROOT/ios/Frameworks/VzhukhTunnelCore.xcframework"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Matches the Flutter project's minimum. Raise both together or the linker
# will complain that the archive is older than everything around it.
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}"

# build_slice <name> <sdk> <goarch> <min-version-flag>
build_slice() {
  local name="$1"
  local sdk="$2"
  local goarch="$3"
  local min_flag="$4"

  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local clang
  clang="$(xcrun --sdk "$sdk" --find clang)"

  local out="$STAGE/$name"
  mkdir -p "$out"

  echo "Building $name ($sdk, $goarch) …"
  cd "$GO_SRC"

  # Both the compiler and the linker need the sysroot and the architecture:
  # cgo compiles C with the first and links the archive's C half with the
  # second, and a mismatch there produces an archive that builds and then
  # fails to link into the extension.
  local flags="-isysroot $sysroot -arch $(clang_arch "$goarch") $min_flag"

  env GOOS=ios \
      GOARCH="$goarch" \
      CGO_ENABLED=1 \
      CC="$clang" \
      CXX="$clang++" \
      CGO_CFLAGS="$flags" \
      CGO_LDFLAGS="$flags" \
    go build \
      -buildmode=c-archive \
      -trimpath \
      -tags "with_gvisor,ios" \
      -o "$out/$LIB_NAME.a" \
      ./ios

  # cgo writes the header next to the archive; Swift needs it, plus the hand
  # written one it includes.
  mkdir -p "$out/include"
  mv "$out/$LIB_NAME.h" "$out/include/"
  cp "$GO_SRC/ios/bridge.h" "$out/include/"
  write_modulemap "$out/include/module.modulemap"

  echo "  -> $out/$LIB_NAME.a"
}

clang_arch() {
  case "$1" in
    arm64) echo "arm64" ;;
    amd64) echo "x86_64" ;;
    *) echo "unsupported GOARCH: $1" >&2; exit 1 ;;
  esac
}

# The modulemap is what lets the extension write `import VzhukhTunnel` instead
# of carrying a bridging header around.
write_modulemap() {
  cat > "$1" <<'MODULEMAP'
module VzhukhTunnelCore {
    header "libvzhukhtunnel.h"
    export *
}
MODULEMAP
}

build_slice "device"    "iphoneos"        "arm64" "-miphoneos-version-min=$DEPLOYMENT_TARGET"
build_slice "simulator" "iphonesimulator" "arm64" "-mios-simulator-version-min=$DEPLOYMENT_TARGET"

echo "Assembling the xcframework …"
rm -rf "$FRAMEWORK"
mkdir -p "$(dirname "$FRAMEWORK")"

xcodebuild -create-xcframework \
  -library "$STAGE/device/$LIB_NAME.a"    -headers "$STAGE/device/include" \
  -library "$STAGE/simulator/$LIB_NAME.a" -headers "$STAGE/simulator/include" \
  -output "$FRAMEWORK" >/dev/null

echo ""
echo "Done: $FRAMEWORK"
du -sh "$FRAMEWORK"

# Only an Apple Silicon simulator slice is built. An Intel Mac would need a
# GOARCH=amd64 one as well, fused into the simulator library with lipo.
