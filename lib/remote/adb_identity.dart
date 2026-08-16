import 'dart:isolate';

import '../storage/secure_store.dart';
import 'adb/adb_key.dart';

/// Loads the ADB identity, minting one on first use.
///
/// The key is kept because the television remembers the fingerprint it was
/// asked to trust: reusing it means the confirmation dialog appears once ever
/// rather than at every connection. Generating RSA-2048 takes seconds, so it
/// happens off the UI isolate.
class LoadAdbIdentity {
  const LoadAdbIdentity();
  static const _key = 'adb_identity';

  Future<AdbKey> call() async {
    final existing = await secureStore.read(key: _key);
    if (existing != null) {
      try {
        return AdbKey.fromJson(existing);
      } catch (_) {
        // A corrupt entry is not worth recovering; mint a fresh one below.
      }
    }

    final generated = await Isolate.run(() => AdbKey.generate().toJson());
    await secureStore.write(key: _key, value: generated);
    return AdbKey.fromJson(generated);
  }
}
