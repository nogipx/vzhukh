import 'dart:io';

import 'secure_store.dart';

/// Storage for what is not secret: server addresses, routes, rules.
///
/// On macOS these live in files under Application Support, not the
/// keychain. Every keychain item belongs to the code signature that created
/// it, and an ad-hoc signed build gets a new signature with every build, so
/// each read of an item asked the user again. That was a prompt every few
/// seconds while the Traffic tab refreshed rule names. Private keys stay in
/// the keychain (see [secureStore]); they are read once per connect.
///
/// Elsewhere this is [secureStore] as before.
class PlainStore {
  const PlainStore();

  static Directory get _dir => Directory(
      '${Platform.environment['HOME']}/Library/Application Support/dev.nogipx.vzhukh');

  static File _file(String key) =>
      File('${_dir.path}/${key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.json');

  Future<String?> read({required String key}) async {
    if (!Platform.isMacOS) return secureStore.read(key: key);
    final file = _file(key);
    if (await file.exists()) return file.readAsString();

    // Written by an earlier version: move it out of the keychain, once.
    String? legacy;
    try {
      legacy = await secureStore.read(key: key);
    } catch (_) {}
    if (legacy != null) {
      await write(key: key, value: legacy);
      try {
        await secureStore.delete(key: key);
      } catch (_) {}
    }
    return legacy;
  }

  Future<void> write({required String key, required String value}) async {
    if (!Platform.isMacOS) return secureStore.write(key: key, value: value);
    await _dir.create(recursive: true);
    // Write then rename, so a crash midway never leaves half a file.
    final tmp = File('${_file(key).path}.tmp');
    await tmp.writeAsString(value, flush: true);
    await tmp.rename(_file(key).path);
  }

  Future<void> delete({required String key}) async {
    if (!Platform.isMacOS) return secureStore.delete(key: key);
    final file = _file(key);
    if (await file.exists()) await file.delete();
    try {
      await secureStore.delete(key: key);
    } catch (_) {}
  }
}

const plainStore = PlainStore();
