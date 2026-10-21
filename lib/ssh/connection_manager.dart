import 'dart:math';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../storage/server_repository.dart';
import 'admin_session.dart';
import 'key_generator.dart';
import 'server_access.dart';

/// Derives a safe Linux username from a human-readable label.
/// Result is always prefixed with "vzhukh_", max 32 chars total.
/// Example: "Alice's phone" → "vzhukh_alice_s_phone"
String usernameFromLabel(String label) {
  final slug = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final part = slug.isEmpty ? 'user' : slug.substring(0, slug.length.clamp(0, 24));
  return 'vzhukh_$part';
}

/// Generates a key pair, creates a dedicated Linux user for [label],
/// installs the public key with restrict,port-forwarding, saves the
/// Connection (without private key) to [repository], and returns the
/// full Connection including the private key for export as invite.
///
/// The private key is NOT stored locally — returned only for export.
/// [kind] and [createdBy] go on the server with the label (UserNote), so
/// the access list on any device says who the user is. A name already
/// taken on the server gets a random ending.
class AddConnection {
  final ServerRepository repository;
  final GenerateSshKeyPair _generateKey;

  AddConnection(this.repository) : _generateKey = const GenerateSshKeyPair();

  Future<Connection> call(
    Server server,
    SshIdentity adminIdentity,
    String label, {
    AccessKind kind = AccessKind.friend,
    String createdBy = '',
    AdminShell? shell,
  }) async {
    final createdAt = DateTime.now();
    final note = UserNote(kind: kind, label: label, createdAt: createdAt, createdBy: createdBy);

    Future<(String, SshKeyPairResult)> make(AdminShell sh) async {
      var username = usernameFromLabel(label);
      final taken = await sh.run('getent passwd ${AdminShell.quote(username)} >/dev/null && echo taken || true');
      if (taken.trim() == 'taken') {
        final suffix = Random.secure().nextInt(0x10000).toRadixString(16).padLeft(4, '0');
        username = '${username.substring(0, username.length.clamp(0, 27))}_$suffix';
      }
      final keyPair = _generateKey(comment: username);
      await _setupUser(sh, username, keyPair.publicKeyOpenSSH, note);
      return (username, keyPair);
    }

    // An open shell is reused: logging in again would cost a key exchange.
    final (username, keyPair) =
        shell != null ? await make(shell) : await const WithAdminShell()(server, adminIdentity, make);

    final id = '${server.id}_${createdAt.millisecondsSinceEpoch}';

    // Store only the public key — private key goes into the invite, not storage.
    final storedConnection = Connection(
      id: id,
      serverId: server.id,
      label: label,
      username: username,
      publicKeyOpenSSH: keyPair.publicKeyOpenSSH,
      createdAt: createdAt,
    );
    await repository.saveConnection(storedConnection);

    // Return the full connection (with private key) for the caller to export.
    return Connection(
      id: id,
      serverId: server.id,
      label: label,
      username: username,
      publicKeyOpenSSH: keyPair.publicKeyOpenSSH,
      privateKeyPem: keyPair.privateKeyPem,
      createdAt: createdAt,
    );
  }

  Future<void> _setupUser(AdminShell sh, String username, String pubkey, UserNote note) async {
    final u = AdminShell.quote(username);
    await sh.run('useradd -m -s /bin/false -c ${AdminShell.quote(note.encode())} $u');

    final restrictedEntry = 'restrict,port-forwarding $pubkey';
    await sh.run([
      'mkdir -p /home/$username/.ssh',
      'echo ${AdminShell.quote(restrictedEntry)} > /home/$username/.ssh/authorized_keys',
      'chmod 700 /home/$username/.ssh',
      'chmod 600 /home/$username/.ssh/authorized_keys',
      'chown -R $username:$username /home/$username/.ssh',
    ].join(' && '));
  }
}

/// Deletes the Linux user for [connection], ending its sessions, and
/// removes it from local storage.
class RevokeConnection {
  final ServerRepository repository;

  const RevokeConnection(this.repository);

  Future<void> call(
    Server server,
    SshIdentity adminIdentity,
    Connection connection,
  ) async {
    await const WithAdminShell()(server, adminIdentity, (sh) => const RemoveServerUser()(sh, connection.username));
    await repository.deleteConnection(connection);
  }
}
