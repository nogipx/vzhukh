set shell := ["bash", "-uc"]

version := `grep '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f1`
apk_debug := "build/app/outputs/flutter-apk/app-debug.apk"
apk_release := "build/app/outputs/flutter-apk/app-release.apk"
macos_app := "build/macos/Build/Products/Release/vzhukh.app"

_default:
    @just --list

# Static analysis over everything we write by hand.
analyze:
    fvm flutter analyze lib/ tool/

test:
    fvm dart test

# --- Android ---------------------------------------------------------------

# Debug APK. Universal: every ABI, which is what installing onto a TV needs.
apk:
    fvm flutter build apk --debug

apk-release:
    fvm flutter build apk --release

# Rebuild the Go tunnel library for all ABIs. Needed after touching go/.
native:
    ./scripts/build_native.sh

# Install onto a device. `just install` picks the only one attached.
install target="":
    #!/usr/bin/env bash
    set -euo pipefail
    apk="{{apk_debug}}"
    [ -f "$apk" ] || { echo "no APK yet — run: just apk"; exit 1; }
    if [ -n "{{target}}" ]; then
        adb -s "{{target}}" install -r "$apk"
    else
        adb install -r "$apk"
    fi

# List the ABIs a package carries
abis apk=apk_debug:
    # A build made for one phone holds only that phone's architecture, and
    # installing it on a 32-bit TV fails at launch rather than at install.
    @unzip -l "{{apk}}" | grep -oE 'lib/[a-z0-9_-]+/' | sort -u

# --- macOS -----------------------------------------------------------------

macos:
    fvm flutter build macos --release

# Build the macOS app and wrap it in a DMG
dmg: macos
    #!/usr/bin/env bash
    # Signed with whatever certificate the project is set to. That is a
    # development one unless changed, which Gatekeeper will not accept on
    # anyone else's machine without notarisation.
    set -euo pipefail
    out="build/dist/Vzhukh-{{version}}.dmg"
    mkdir -p build/dist
    rm -f "$out"

    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    cp -R "{{macos_app}}" "$stage/"

    if command -v create-dmg >/dev/null; then
        create-dmg \
            --volname "Vzhukh" \
            --window-pos 200 120 --window-size 600 380 \
            --icon-size 110 \
            --icon "vzhukh.app" 150 180 \
            --hide-extension "vzhukh.app" \
            --app-drop-link 450 180 \
            --no-internet-enable \
            "$out" "$stage"
    else
        # Plain image: no layout, but no extra tool either.
        ln -s /Applications "$stage/Applications"
        hdiutil create -volname "Vzhukh" -srcfolder "$stage" -ov -format UDZO "$out"
    fi

    echo
    ls -lh "$out"
    codesign -dvvv "{{macos_app}}" 2>&1 | grep -E 'Authority=Apple Development|Authority=Developer ID|TeamIdentifier' || true

# --- TV remote -------------------------------------------------------------

# Exercise the TV remote against a real set
probe-tv host="192.168.0.168":
    # Checks the protocol end to end without the adb binary. The set asks for
    # confirmation the first time a new key is used.
    fvm dart run tool/tv_remote_probe.dart {{host}}

probe-adb host="192.168.0.168" port="5555":
    fvm dart run tool/adb_probe.dart {{host}} {{port}}

# --- housekeeping ----------------------------------------------------------

clean:
    fvm flutter clean
    rm -rf build/dist
