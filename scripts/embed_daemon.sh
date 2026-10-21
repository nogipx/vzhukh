#!/bin/sh
# Copies vzhukhd into the app's Resources. Run by Xcode as a build phase of
# the macOS Runner target (scripts/setup_macos_daemon.rb adds it).
#
# It only copies: building Go from inside Xcode would need Go on Xcode's
# PATH. `just daemon` builds the binary, and `just macos` runs it first.
set -eu

src="${SRCROOT}/../build/daemon/vzhukhd"
dst="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/vzhukhd"

if [ ! -f "$src" ]; then
    echo "warning: no helper at $src; this build cannot install it. Run: just daemon"
    exit 0
fi
mkdir -p "$(dirname "$dst")"
cp -f "$src" "$dst"
chmod 0755 "$dst"
