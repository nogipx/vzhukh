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

# --- Go tunnel -------------------------------------------------------------

# Unit tests for the Go tunnel engine. Runs a real SSH server in-process.
go-test:
    cd go/tun2socks && go test ./internal/... -race -count=1

# Rebuild the Go tunnel for iOS. Needed after touching go/.
native-ios:
    ./scripts/build_ios.sh

# --- iOS -------------------------------------------------------------------

# Add the packet tunnel extension to the Xcode project.
# Needs a paid Apple Developer Program membership: packet-tunnel-provider is
# not available to a free Personal Team, and without it the app will not sign.
ios-tunnel-on:
    ruby scripts/setup_ios_extension.rb

# Take the extension back out, leaving an app that builds on a free account.
ios-tunnel-off:
    ruby scripts/setup_ios_extension.rb remove

ios:
    fvm flutter build ios --release

# Drive the SSH chain against a real server, with no TUN and no iOS involved.
# Proves the half of the iOS tunnel that Apple has nothing to do with.
#
#   just tunnel-test -host 1.2.3.4 -user root -password hunter2
#   just tunnel-test -config chain.json -socks 127.0.0.1:2080
tunnel-test *args:
    cd go/tun2socks && go run ./cmd/tunneltest {{args}}

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

# Build a DMG that runs on machines other than this one
dmg-portable: macos
    #!/usr/bin/env bash
    # A development signature carries a provisioning profile naming the exact
    # Macs allowed to run the build — everywhere else the system refuses to
    # launch it at all, which reads as "the application cannot be opened".
    #
    # Dropping the profile and signing ad-hoc removes that restriction. What
    # remains is Gatekeeper's own check, which the recipient clears once by
    # opening from the context menu. Proper distribution wants a Developer ID
    # certificate and notarisation instead; see `just notarise-help`.
    set -euo pipefail

    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    cp -R "{{macos_app}}" "$stage/"
    app="$stage/vzhukh.app"

    rm -f "$app/Contents/embedded.provisionprofile"

    # Nested code first: a bundle's signature covers what is inside it.
    find "$app/Contents/Frameworks" -name '*.framework' -maxdepth 1 -print0 2>/dev/null |
        while IFS= read -r -d '' fw; do codesign --force --sign - "$fw"; done
    find "$app/Contents" \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null |
        while IFS= read -r -d '' lib; do codesign --force --sign - "$lib"; done

    codesign --force --sign - \
        --entitlements macos/Runner/Portable.entitlements \
        "$app"
    codesign --verify --deep --strict "$app" && echo "signature ok"

    out="build/dist/Vzhukh-{{version}}-portable.dmg"
    mkdir -p build/dist
    rm -f "$out"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "Vzhukh" -srcfolder "$stage" -ov -format UDZO "$out"

    echo
    ls -lh "$out"
    echo "On the other Mac: right-click the app, choose Open, confirm once."

# What proper distribution needs
notarise-help:
    @echo "Needs a paid Apple Developer account, which the development"
    @echo "certificate already implies. Then:"
    @echo
    @echo "  1. Xcode > Settings > Accounts > Manage Certificates"
    @echo "     add a 'Developer ID Application' certificate"
    @echo "  2. Sign the app with it instead of ad-hoc"
    @echo "  3. xcrun notarytool submit <dmg> --apple-id <id> \\"
    @echo "       --team-id 3KCLFXFC74 --password <app-specific> --wait"
    @echo "  4. xcrun stapler staple <dmg>"
    @echo
    @echo "Result opens with no warning at all, on any Mac."

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
