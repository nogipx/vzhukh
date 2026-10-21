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

# Dart tests. A Flutter package: `dart test` cannot load flutter_test.
# The tunnel tests build an SSH server from go/, so Go has to be on PATH.
test:
    fvm flutter test

# --- Android ---------------------------------------------------------------

# Debug APK. Universal: every ABI, which is what installing onto a TV needs.
apk:
    fvm flutter build apk --debug

apk-release:
    fvm flutter build apk --release

# Rebuild the Go tunnel library for all ABIs. Needed after touching go/.
native:
    ./scripts/build_native.sh

# Install onto a device. `just install` picks the only one attached and
# installs the release build; `just install <serial> debug` for the debug one.
install target="" mode="release":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{mode}}" = "debug" ]; then apk="{{apk_debug}}"; build="just apk"; else apk="{{apk_release}}"; build="just apk-release"; fi
    [ -f "$apk" ] || { echo "no APK yet — run: $build"; exit 1; }
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
    cd go/tun2socks && go test -tags with_gvisor ./internal/... -race -count=1

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

# The app carries its root helper (go/tun2socks/cmd/vzhukhd), copied in by
# an Xcode build phase, so the helper is built first.
macos: daemon
    fvm flutter build macos --release

# Build vzhukhd, the macOS helper, for both architectures. with_gvisor is
# what puts the packet stack in; without it sing-tun builds and then refuses
# to start.
daemon:
    #!/usr/bin/env bash
    set -euo pipefail
    out=build/daemon
    mkdir -p "$out"
    cd go/tun2socks
    CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -tags with_gvisor -o "../../$out/vzhukhd-arm64" ./cmd/vzhukhd
    CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -trimpath -tags with_gvisor -o "../../$out/vzhukhd-amd64" ./cmd/vzhukhd
    cd ../..
    lipo -create -output "$out/vzhukhd" "$out/vzhukhd-arm64" "$out/vzhukhd-amd64"
    rm "$out/vzhukhd-arm64" "$out/vzhukhd-amd64"
    # lipo drops the linker's ad-hoc signatures; Apple silicon runs nothing
    # unsigned.
    codesign --force --sign - "$out/vzhukhd"
    lipo -info "$out/vzhukhd"
    cd go/tun2socks && go build -trimpath -o "../../$out/vzhukhctl" ./cmd/vzhukhctl

# Talk to the installed helper: just ctl status | flows | stop
ctl *args:
    build/daemon/vzhukhctl {{args}}

# Install udpgw on a server, so UDP (QUIC, calls) can go through routes:
#   just udpgw-install root@1.2.3.4
# Needs an account there that can sudo. Listens on 127.0.0.1:7300 only.
udpgw-install target:
    #!/usr/bin/env bash
    set -euo pipefail
    arch=$(ssh "{{target}}" uname -m)
    case "$arch" in
        x86_64) goarch=amd64 ;;
        aarch64|arm64) goarch=arm64 ;;
        *) echo "unsupported architecture: $arch"; exit 1 ;;
    esac
    mkdir -p build/udpgw
    (cd go/tun2socks && CGO_ENABLED=0 GOOS=linux GOARCH=$goarch go build -trimpath -o "../../build/udpgw/udpgw-$goarch" ./cmd/udpgw)
    scp "build/udpgw/udpgw-$goarch" "{{target}}:/tmp/vzhukh-udpgw"
    ssh "{{target}}" 'sudo sh -s' <<'REMOTE'
    set -e
    install -o root -g root -m 0755 /tmp/vzhukh-udpgw /usr/local/bin/vzhukh-udpgw
    rm -f /tmp/vzhukh-udpgw
    cat > /etc/systemd/system/vzhukh-udpgw.service <<UNIT
    [Unit]
    Description=vzhukh udpgw: UDP for clients that reach this server over SSH
    After=network.target

    [Service]
    ExecStart=/usr/local/bin/vzhukh-udpgw -listen 127.0.0.1:7300
    DynamicUser=yes
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now vzhukh-udpgw
    systemctl --no-pager status vzhukh-udpgw | head -3
    REMOTE

# Re-add the Xcode phase that embeds vzhukhd, after `flutter create`.
daemon-xcode:
    ruby scripts/setup_macos_daemon.rb

# Follow the installed helper's log
daemon-log:
    tail -f /var/log/vzhukhd.log

# Build the macOS app and wrap it in a DMG
dmg: macos
    #!/usr/bin/env bash
    # The project signs ad-hoc, with no Apple team: nothing expires and no
    # list of allowed Macs. Another Mac still asks once, through Gatekeeper.
    set -euo pipefail
    out="build/dist/vzhukh-{{version}}-macos.dmg"
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
            --skip-jenkins \
            "$out" "$stage"
    else
        # Plain image: no layout, but no extra tool either.
        ln -s /Applications "$stage/Applications"
        hdiutil create -volname "Vzhukh" -srcfolder "$stage" -ov -format UDZO "$out"
    fi

    echo
    ls -lh "$out"
    codesign -dvvv "{{macos_app}}" 2>&1 | grep -E '^Signature|TeamIdentifier' || true
    echo "On another Mac: open the app once, then System Settings >"
    echo "Privacy & Security > Open Anyway."

# --- Release ---------------------------------------------------------------

# Bump `version:` in pubspec.yaml first: Android installs an update only over
# a lower build number. Builds one APK for any device (TVs included), smaller
# per-ABI APKs and the macOS DMG.
# Everything a GitHub release carries, into build/dist
release: _release-key dmg
    #!/usr/bin/env bash
    set -euo pipefail
    v="{{version}}"
    mkdir -p build/dist
    fvm flutter build apk --release
    cp build/app/outputs/flutter-apk/app-release.apk "build/dist/vzhukh-$v-android.apk"
    fvm flutter build apk --release --split-per-abi
    for abi in arm64-v8a armeabi-v7a x86_64; do
        cp "build/app/outputs/flutter-apk/app-$abi-release.apk" "build/dist/vzhukh-$v-android-$abi.apk"
    done
    echo
    ls -lh build/dist

# A published APK signed with anything but the release key could never be
# updated by the next one.
_release-key:
    @[ -f android/key.properties ] || { echo "android/key.properties is missing: no release key, refusing to build a release"; exit 1; }

# --- TV remote -------------------------------------------------------------

# Exercise the TV remote against a real set: just probe-tv <tv-ip>
probe-tv host:
    # Checks the protocol end to end without the adb binary. The set asks for
    # confirmation the first time a new key is used.
    fvm dart run tool/tv_remote_probe.dart {{host}}

probe-adb host port="5555":
    fvm dart run tool/adb_probe.dart {{host}} {{port}}

# --- housekeeping ----------------------------------------------------------

clean:
    fvm flutter clean
    rm -rf build/dist

# --- Icons -----------------------------------------------------------------

# Rebuild every app icon from assets/branding/*.svg. Needs rsvg-convert.
icons:
    ./scripts/build_icons.sh
