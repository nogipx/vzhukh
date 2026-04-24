import 'package:dartssh2/dartssh2.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../storage/server_repository.dart';
import 'key_generator.dart';
import 'ssh_client_factory.dart';

const _ownerUsername = 'vzhukh_owner';

/// Connects to [server] using [adminIdentity] (password auth),
/// creates the 'flume' system user, installs the owner's Ed25519 key
/// with restrict,port-forwarding, saves the [Connection] to [repository].
///
/// Returns the [Connection] including the private key so the caller
/// can connect immediately (and optionally export it as an invite).
class ProvisionServer {
  final ServerRepository repository;
  final GenerateSshKeyPair _generateKey;

  ProvisionServer(this.repository) : _generateKey = const GenerateSshKeyPair();

  Future<Connection> call(Server server, SshIdentity adminIdentity) async {
    final keyPair = _generateKey(comment: _ownerUsername);

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
      await _runSetupCommands(client, keyPair.publicKeyOpenSSH);
    } finally {
      client.close();
      await socket.done;
    }

    // Owner connection stores the private key so they can connect from this device.
    final connection = Connection(
      id: '${server.id}_owner',
      serverId: server.id,
      label: 'Owner',
      username: _ownerUsername,
      publicKeyOpenSSH: keyPair.publicKeyOpenSSH,
      privateKeyPem: keyPair.privateKeyPem,
      createdAt: DateTime.now(),
    );

    await repository.saveConnection(connection);
    return connection;
  }

  Future<void> _runSetupCommands(SSHClient client, String pubkey) async {
    await _exec(client, 'useradd -m -s /bin/false $_ownerUsername');

    final restrictedEntry = 'restrict,port-forwarding $pubkey';
    await _exec(client, [
      'mkdir -p /home/$_ownerUsername/.ssh',
      'echo ${_shellQuote(restrictedEntry)} > /home/$_ownerUsername/.ssh/authorized_keys',
      'chmod 700 /home/$_ownerUsername/.ssh',
      'chmod 600 /home/$_ownerUsername/.ssh/authorized_keys',
      'chown -R $_ownerUsername:$_ownerUsername /home/$_ownerUsername/.ssh',
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
