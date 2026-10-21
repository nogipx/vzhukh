import 'dart:convert';

import 'package:local_auth/local_auth.dart';

import '../models/ssh_identity.dart';
import 'plain_store.dart';
import 'secure_store.dart';

/// Admin passwords the user chose to keep on this device, one per server.
///
/// They live in the keychain / Keystore and are read only after the device
/// owner unlocks them ([UnlockWithDevice]). They never leave the device:
/// sharing and sync do not see them. Whether one is saved is kept apart, in
/// plain storage, so screens can say so without touching the keychain.
class AdminCredentials {
  const AdminCredentials();

  static String _secret(String serverId) => 'admin_$serverId';
  static String _flag(String serverId) => 'admin_saved_$serverId';

  Future<bool> has(String serverId) async => await plainStore.read(key: _flag(serverId)) != null;

  Future<void> save(SshIdentity admin) async {
    await secureStore.write(
      key: _secret(admin.serverId),
      value: jsonEncode({'username': admin.username, 'password': admin.password}),
    );
    await plainStore.write(key: _flag(admin.serverId), value: '1');
  }

  /// The saved credentials. Callers unlock first.
  Future<SshIdentity?> read(String serverId) async {
    final raw = await secureStore.read(key: _secret(serverId));
    if (raw == null) return null;
    final j = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    return SshIdentity(
      id: 'admin_saved',
      serverId: serverId,
      username: j['username'] as String,
      authType: SshAuthType.password,
      isAdmin: true,
      password: j['password'] as String?,
    );
  }

  Future<void> forget(String serverId) async {
    await secureStore.delete(key: _secret(serverId));
    await plainStore.delete(key: _flag(serverId));
  }
}

/// Asks the device owner to prove it is them: fingerprint, face, Touch ID,
/// or the device PIN / password when there is no biometric.
class UnlockWithDevice {
  const UnlockWithDevice();

  static final _auth = LocalAuthentication();

  /// Whether this device can ask at all (a lock screen is set up).
  Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> call(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
    } catch (_) {
      return false;
    }
  }
}
