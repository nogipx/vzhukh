import 'package:dartssh2/dartssh2.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../storage/server_repository.dart';
import 'key_generator.dart';

const _tunnelUsername = 'flume';

/// Generates a key pair, installs the public key on the server for [label],
/// saves the connection (without private key) to [repository], and returns
/// the full [Connection] including the private key for export as invite.
///
/// The private key is NOT stored locally — it is only returned here so the
/// caller can export it as an encrypted invite for the recipient.
class AddConnection {
  final ServerRepository repository;
  final GenerateSshKeyPair _generateKey;

  AddConnection(this.repository) : _generateKey = const GenerateSshKeyPair();

  Future<Connection> call(
    Server server,
    SshIdentity adminIdentity,
    String label,
  ) async {
    final keyPair = _generateKey(comment: label.replaceAll(' ', '_'));

    final socket = await SSHSocket.connect(server.host, server.port);
    final client = SSHClient(
      socket,
      username: adminIdentity.username,
      onPasswordRequest: adminIdentity.password != null
          ? () => adminIdentity.password!
          : null,
      identities: adminIdentity.privateKeyPem != null
          ? [...SSHKeyPair.fromPem(adminIdentity.privateKeyPem!)]
          : null,
    );

    try {
      await client.authenticated;
      await _appendAuthorizedKey(client, keyPair.publicKeyOpenSSH);
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
      publicKeyOpenSSH: keyPair.publicKeyOpenSSH,
      createdAt: DateTime.now(),
    );
    await repository.saveConnection(storedConnection);

    // Return the full connection (with private key) for the caller to export.
    return Connection(
      id: id,
      serverId: server.id,
      label: label,
      publicKeyOpenSSH: keyPair.publicKeyOpenSSH,
      privateKeyPem: keyPair.privateKeyPem,
      createdAt: storedConnection.createdAt,
    );
  }

  Future<void> _appendAuthorizedKey(SSHClient client, String pubkey) async {
    // restrict,port-forwarding limits the key to port forwarding only.
    // No shell, no X11, no agent forwarding, no command execution.
    final restrictedEntry = 'restrict,port-forwarding $pubkey';
    final escaped = _shellQuote(restrictedEntry);
    await _exec(
      client,
      'echo $escaped >> /home/$_tunnelUsername/.ssh/authorized_keys',
    );
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

/// Removes a connection's public key from authorized_keys and deletes it
/// from local storage.
class RevokeConnection {
  final ServerRepository repository;

  const RevokeConnection(this.repository);

  Future<void> call(
    Server server,
    SshIdentity adminIdentity,
    Connection connection,
  ) async {
    final socket = await SSHSocket.connect(server.host, server.port);
    final client = SSHClient(
      socket,
      username: adminIdentity.username,
      onPasswordRequest: adminIdentity.password != null
          ? () => adminIdentity.password!
          : null,
      identities: adminIdentity.privateKeyPem != null
          ? [...SSHKeyPair.fromPem(adminIdentity.privateKeyPem!)]
          : null,
    );

    try {
      await client.authenticated;
      await _removeKey(client, connection.publicKeyOpenSSH);
    } finally {
      client.close();
      await socket.done;
    }

    await repository.deleteConnection(connection);
  }

  Future<void> _removeKey(SSHClient client, String pubkey) async {
    // The authorized_keys line starts with "restrict,port-forwarding ssh-ed25519 ..."
    // Match by the key body (everything after "restrict,port-forwarding ").
    final keyBody = _shellQuote(pubkey);
    final authKeysPath = '/home/$_tunnelUsername/.ssh/authorized_keys';

    // Use grep to remove lines containing the key. The key is unique per connection.
    await _exec(
      client,
      'grep -v $keyBody $authKeysPath > /tmp/.ak_tmp && mv /tmp/.ak_tmp $authKeysPath && chmod 600 $authKeysPath',
    );
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
