import 'package:dartssh2/dartssh2.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../storage/server_repository.dart';
import 'key_generator.dart';
import 'ssh_client_factory.dart';

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
class AddConnection {
  final ServerRepository repository;
  final GenerateSshKeyPair _generateKey;

  AddConnection(this.repository) : _generateKey = const GenerateSshKeyPair();

  Future<Connection> call(
    Server server,
    SshIdentity adminIdentity,
    String label,
  ) async {
    final username = usernameFromLabel(label);
    final keyPair = _generateKey(comment: username);

    final socket = await SSHSocket.connect(server.host, server.port);
    final client = buildSshClient(
      socket,
      username: adminIdentity.username,
      password: adminIdentity.password,
      identities: adminIdentity.privateKeyPem != null
          ? [...SSHKeyPair.fromPem(adminIdentity.privateKeyPem!)]
          : null,
    );

    try {
      await client.authenticated;
      await _setupUser(client, username, keyPair.publicKeyOpenSSH);
    } finally {
      client.close();
      await socket.done;
    }

    final id = '${server.id}_${DateTime.now().millisecondsSinceEpoch}';

    // Store only the public key — private key goes into the invite, not storage.
    final storedConnection = Connection(
      id: id,
      serverId: server.id,
      label: label,
      username: username,
      publicKeyOpenSSH: keyPair.publicKeyOpenSSH,
      createdAt: DateTime.now(),
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
      createdAt: storedConnection.createdAt,
    );
  }

  Future<void> _setupUser(
    SSHClient client,
    String username,
    String pubkey,
  ) async {
    await _exec(client, 'useradd -m -s /bin/false $username');

    final restrictedEntry = 'restrict,port-forwarding $pubkey';
    await _exec(client, [
      'mkdir -p /home/$username/.ssh',
      'echo ${_shellQuote(restrictedEntry)} > /home/$username/.ssh/authorized_keys',
      'chmod 700 /home/$username/.ssh',
      'chmod 600 /home/$username/.ssh/authorized_keys',
      'chown -R $username:$username /home/$username/.ssh',
    ].join(' && '));
  }

  Future<void> _exec(SSHClient client, String command) async {
    final session = await client.execute(command);
    await session.done;
    final exitCode = session.exitCode;
    if (exitCode != null && exitCode != 0) {
      throw Exception('Remote command failed (exit $exitCode): $command');
    }
  }

  String _shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";
}

/// Deletes the Linux user for [connection] and removes it from local storage.
class RevokeConnection {
  final ServerRepository repository;

  const RevokeConnection(this.repository);

  Future<void> call(
    Server server,
    SshIdentity adminIdentity,
    Connection connection,
  ) async {
    final socket = await SSHSocket.connect(server.host, server.port);
    final client = buildSshClient(
      socket,
      username: adminIdentity.username,
      password: adminIdentity.password,
      identities: adminIdentity.privateKeyPem != null
          ? [...SSHKeyPair.fromPem(adminIdentity.privateKeyPem!)]
          : null,
    );

    try {
      await client.authenticated;
      // -r removes home directory and mail spool.
      await _exec(client, 'userdel -r ${connection.username}');
    } finally {
      client.close();
      await socket.done;
    }

    await repository.deleteConnection(connection);
  }

  Future<void> _exec(SSHClient client, String command) async {
    final session = await client.execute(command);
    await session.done;
    final exitCode = session.exitCode;
    if (exitCode != null && exitCode != 0) {
      throw Exception('Remote command failed (exit $exitCode): $command');
    }
  }
}
