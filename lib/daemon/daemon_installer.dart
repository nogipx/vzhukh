import 'dart:io';

/// Where the helper lives once installed, and where the app carries it.
///
/// It runs from /Library/PrivilegedHelperTools, root-owned, never from inside
/// the app bundle: the user can write to the bundle, and a root process
/// started from there would let anything running as the user replace it.
abstract final class DaemonInstallation {
  static const label = 'dev.nogipx.vzhukh.daemon';
  static const binaryPath = '/Library/PrivilegedHelperTools/$label';
  static const plistPath = '/Library/LaunchDaemons/$label.plist';
  static const logPath = '/var/log/vzhukhd.log';

  /// The binary inside this app's bundle (Contents/Resources/vzhukhd).
  static File bundledBinary() {
    final macOS = File(Platform.resolvedExecutable).parent;
    return File('${macOS.parent.path}/Resources/vzhukhd');
  }

  static bool get isInstalled => File(plistPath).existsSync();
}

/// The user pressed Cancel on the password dialog.
class InstallCancelled implements Exception {
  const InstallCancelled();
  @override
  String toString() => 'Cancelled';
}

/// Runs [script] as root with `sh -c`, after the system asks for an
/// administrator's password.
///
/// Arguments go through AppleScript's `quoted form of`, so nothing in them is
/// ever parsed as shell. The script is passed inline rather than written to a
/// temporary file, which another process of this user could swap between the
/// write and the run.
Future<void> _runAsAdmin(String script, List<String> args, String prompt) async {
  final quotedArgs = [
    for (var i = 0; i < args.length; i++) '" " & quoted form of (item ${i + 3} of argv)',
  ].join(' & ');
  final result = await Process.run('/usr/bin/osascript', [
    '-e',
    'on run argv',
    '-e',
    'do shell script "/bin/sh -c " & quoted form of (item 1 of argv) & '
        '" " & quoted form of (item 2 of argv)'
        '${quotedArgs.isEmpty ? '' : ' & $quotedArgs'} '
        'with prompt "$prompt" with administrator privileges',
    '-e',
    'end run',
    script,
    'vzhukh',
    ...args,
  ]);
  if (result.exitCode != 0) {
    final err = '${result.stderr}'.trim();
    if (err.contains('-128') || err.contains('User canceled')) {
      throw const InstallCancelled();
    }
    throw Exception(err.isEmpty ? 'osascript exited ${result.exitCode}' : err);
  }
}

Future<int> _currentUid() async {
  final result = await Process.run('/usr/bin/id', ['-u']);
  final uid = int.tryParse('${result.stdout}'.trim());
  if (uid == null) throw Exception('Cannot tell who is logged in');
  return uid;
}

const _installScript = r'''
set -eu
SRC="$1"
ALLOWED_UID="$2"
LABEL=dev.nogipx.vzhukh.daemon
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

launchctl bootout system/$LABEL 2>/dev/null || true
mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 0755 "$SRC" "$BIN"
xattr -c "$BIN" 2>/dev/null || true

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>-uid</string>
    <string>$ALLOWED_UID</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/vzhukhd.log</string>
  <key>StandardErrorPath</key><string>/var/log/vzhukhd.log</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 0644 "$PLIST"
launchctl bootstrap system "$PLIST"
''';

const _restartScript = r'''
set -eu
launchctl kickstart -k system/dev.nogipx.vzhukh.daemon
''';

const _uninstallScript = r'''
set -u
LABEL=dev.nogipx.vzhukh.daemon
BIN=/Library/PrivilegedHelperTools/$LABEL
# A clean stop puts the DNS settings back; -restore-dns covers a daemon that
# died before it could.
launchctl bootout system/$LABEL 2>/dev/null || true
[ -x "$BIN" ] && "$BIN" -restore-dns || true
rm -f "$BIN" /Library/LaunchDaemons/$LABEL.plist /var/run/vzhukhd.sock
''';

/// Installs or updates the helper from this app's bundle.
class InstallDaemon {
  const InstallDaemon();

  Future<void> call() async {
    final binary = DaemonInstallation.bundledBinary();
    if (!binary.existsSync()) {
      throw Exception(
          'This build carries no helper (${binary.path}). Build it with: just daemon');
    }
    final uid = await _currentUid();
    await _runAsAdmin(
      _installScript,
      [binary.path, '$uid'],
      'vzhukh installs a network helper to route traffic by app and domain.',
    );
  }
}

/// Restarts the helper through launchd, for one that does not answer or is
/// too old to restart itself.
class RestartDaemon {
  const RestartDaemon();

  Future<void> call() => _runAsAdmin(
        _restartScript,
        const [],
        'vzhukh restarts its network helper.',
      );
}

/// Removes the helper and puts the system's DNS settings back.
class UninstallDaemon {
  const UninstallDaemon();

  Future<void> call() => _runAsAdmin(
        _uninstallScript,
        const [],
        'vzhukh removes its network helper.',
      );
}
