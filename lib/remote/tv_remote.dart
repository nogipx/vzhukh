import 'dart:async';
import 'dart:typed_data';

import 'adb/adb_client.dart';
import 'adb/adb_key.dart';
import 'uhid.dart';

class InstalledApp {
  const InstalledApp({required this.packageName, required this.label});

  final String packageName;
  final String label;
}

/// Drives a television over ADB: a virtual mouse and keyboard, plus the few
/// commands worth paying a process launch for.
///
/// Pointer and key events go through uhid because that is the only path that
/// is both permitted and fast; launching or installing an app is a one-off
/// where a slower `am`/`pm` call costs nothing.
class TvRemote {
  TvRemote._(this._client, this._mouse, this._keyboard, this._consumer);

  final AdbClient _client;
  final AdbStream _mouse;
  final AdbStream _keyboard;
  final AdbStream _consumer;

  bool _closed = false;

  static Future<TvRemote> connect({
    required String host,
    int port = 5555,
    required AdbKey key,
    void Function()? onWaitingForAuth,
  }) async {
    final client = await AdbClient.connect(
      host,
      port,
      key,
      onWaitingForAuth: onWaitingForAuth,
    );

    final mouse = await _createDevice(client, 'vzhukh-mouse', Uhid.mouseDescriptor);
    final keyboard =
        await _createDevice(client, 'vzhukh-keyboard', Uhid.keyboardDescriptor);
    final consumer =
        await _createDevice(client, 'vzhukh-consumer', Uhid.consumerDescriptor);

    return TvRemote._(client, mouse, keyboard, consumer);
  }

  static Future<AdbStream> _createDevice(
    AdbClient client,
    String name,
    List<int> descriptor,
  ) async {
    final stream = await client.open('exec:${Uhid.pipeCommand}');
    await stream.write(Uhid.create(name, descriptor));
    // The kernel needs a moment to publish the device before reports land.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return stream;
  }

  // -- pointer ---------------------------------------------------------------

  int _buttons = 0;

  /// Moves the pointer by a relative amount. Values are clamped to what a
  /// single HID report can carry; callers sending large deltas should split
  /// them across frames anyway, or the pointer jumps.
  Future<void> moveBy(int dx, int dy, {int wheel = 0}) =>
      _mouse.write(Uhid.input([
        _buttons,
        _clampSigned(dx),
        _clampSigned(dy),
        _clampSigned(wheel),
      ]));

  Future<void> pressButton(int mask) async {
    _buttons |= mask;
    await _mouse.write(Uhid.input([_buttons, 0, 0, 0]));
  }

  Future<void> releaseButton(int mask) async {
    _buttons &= ~mask;
    await _mouse.write(Uhid.input([_buttons, 0, 0, 0]));
  }

  Future<void> click({int mask = 1}) async {
    await pressButton(mask);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await releaseButton(mask);
  }

  // -- keys ------------------------------------------------------------------

  Future<void> tapKey(int usage, {int modifiers = 0}) async {
    await _keyboard.write(Uhid.input([modifiers, 0, usage, 0, 0, 0, 0, 0]));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await _keyboard.write(Uhid.input([0, 0, 0, 0, 0, 0, 0, 0]));
  }

  /// Presses a consumer key: volume, home, back, media transport.
  Future<void> tapConsumer(int usage) async {
    await _consumer.write(Uhid.input([usage & 0xff, (usage >> 8) & 0xff]));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await _consumer.write(Uhid.input([0, 0]));
  }

  Future<void> home() => tapConsumer(HidConsumer.home);
  Future<void> back() => tapConsumer(HidConsumer.back);
  Future<void> volumeUp() => tapConsumer(HidConsumer.volumeUp);
  Future<void> volumeDown() => tapConsumer(HidConsumer.volumeDown);
  Future<void> mute() => tapConsumer(HidConsumer.mute);

  /// Opens system settings. No consumer usage covers this, so it costs a
  /// process launch — acceptable for something pressed once in a while.
  Future<void> openSettings() =>
      _client.run('am start -a android.settings.SETTINGS');

  // -- apps ------------------------------------------------------------------

  /// Lists launchable packages. Labels are not available this cheaply, so the
  /// package name stands in until the UI asks the TV app for the real one.
  Future<List<InstalledApp>> listApps() async {
    final out = await _client.run(
      'cmd package query-activities '
      '-a android.intent.action.MAIN '
      '-c android.intent.category.LEANBACK_LAUNCHER 2>/dev/null '
      "| grep -o 'packageName=[^ ]*' | sed 's/packageName=//' | sort -u",
    );
    final packages = out
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toSet();

    if (packages.isEmpty) return _listLauncherFallback();
    return [
      for (final p in packages) InstalledApp(packageName: p, label: p),
    ];
  }

  Future<List<InstalledApp>> _listLauncherFallback() async {
    final out = await _client.run('pm list packages -3');
    return [
      for (final line in out.split('\n'))
        if (line.startsWith('package:'))
          InstalledApp(
            packageName: line.substring(8).trim(),
            label: line.substring(8).trim(),
          ),
    ];
  }

  Future<void> launch(String packageName) => _client.run(
        'monkey -p $packageName -c android.intent.category.LEANBACK_LAUNCHER 1 '
        '|| monkey -p $packageName -c android.intent.category.LAUNCHER 1',
      );

  /// Architectures a package carries native code for.
  ///
  /// Read by scanning for the directory names rather than parsing the archive:
  /// zip stores entry paths as plain ASCII, and this avoids a dependency for
  /// one question with a yes or no answer.
  static Set<String> abisIn(Uint8List apk) {
    const known = ['armeabi-v7a', 'armeabi', 'arm64-v8a', 'x86_64', 'x86'];
    final found = <String>{};
    for (final abi in known) {
      if (_contains(apk, 'lib/$abi/')) found.add(abi);
    }
    return found;
  }

  static bool _contains(Uint8List haystack, String needle) {
    final pattern = needle.codeUnits;
    final limit = haystack.length - pattern.length;
    outer:
    for (var i = 0; i <= limit; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (haystack[i + j] != pattern[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// What this device can run.
  Future<List<String>> supportedAbis() async {
    final out = await _client.run('getprop ro.product.cpu.abilist');
    return out.trim().split(',').map((a) => a.trim()).where((a) => a.isNotEmpty).toList();
  }

  /// Copies an APK over and installs it. Used to put Vzhukh itself on a set
  /// that does not have it yet.
  ///
  /// The architectures are checked first because a mismatch installs happily
  /// and only fails when the app is opened, which reads as "it just does not
  /// start" with nothing pointing at the cause.
  Future<String> installApk(Uint8List apk, {String name = 'vzhukh.apk'}) async {
    final packaged = abisIn(apk);
    if (packaged.isNotEmpty) {
      final supported = await supportedAbis();
      if (supported.isNotEmpty && !packaged.any(supported.contains)) {
        throw StateError(
          'This build only has native code for ${packaged.join(', ')}, '
          'and the device needs ${supported.join(', ')}. '
          'Install a universal build on the phone — one made with '
          '`flutter build apk`, not `flutter run`.',
        );
      }
    }

    final remote = '/data/local/tmp/$name';
    // `exec:` already runs this through a shell; nesting another breaks the
    // quoting, the same way it did for the uhid pipe.
    final push = await _client.open('exec:cat > $remote');
    await push.write(apk);
    await push.close();

    final result = await _client.run('pm install -r -t $remote; rm -f $remote');
    return result.trim();
  }

  Future<String> shell(String command) => _client.run(command);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Dropping the pipe closes the descriptor, which removes the device.
    for (final stream in [_mouse, _keyboard, _consumer]) {
      try {
        await stream.write(Uhid.destroy());
      } catch (_) {
        // Already gone; the close below is what matters.
      }
      await stream.close();
    }
    await _client.close();
  }

  static int _clampSigned(int v) {
    final clamped = v.clamp(-127, 127);
    return clamped < 0 ? 256 + clamped : clamped;
  }
}

