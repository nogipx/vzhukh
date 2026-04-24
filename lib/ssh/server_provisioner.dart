import 'package:dartssh2/dartssh2.dart';

import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../storage/server_repository.dart';
import 'key_generator.dart';

const _tunnelUsername = 'flume';

class ProvisionResult {
  final SshIdentity tunnelIdentity;
  final String publicKeyOpenSSH;

  const ProvisionResult({
    required this.tunnelIdentity,
    required this.publicKeyOpenSSH,
  });
}

/// Connects to [server] using [adminIdentity] (password auth),
/// creates the 'flume' system user, installs a generated Ed25519 key,
/// saves the tunnel identity to [repository], and returns it.
///
/// Throws if SSH connection or any remote command fails.
class ProvisionServer {
  final ServerRepository repository;
  final GenerateSshKeyPair _generateKey;

  ProvisionServer(this.repository) : _generateKey = const GenerateSshKeyPair();

  Future<ProvisionResult> call(Server server, SshIdentity adminIdentity) async {
    assert(!adminIdentity.isAdmin == false, 'adminIdentity must have isAdmin=true');
    assert(adminIdentity.serverId == server.id);

    final keyPair = _generateKey();

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
      await _runSetupCommands(client, keyPair.publicKeyOpenSSH);
    } finally {
      client.close();
      await socket.done;
    }

    final tunnelIdentity = SshIdentity(
      id: '${server.id}_tunnel',
      serverId: server.id,
      username: _tunnelUsername,
      authType: SshAuthType.privateKey,
      isAdmin: false,
      privateKeyPem: keyPair.privateKeyPem,
      publicKeyOpenSSH: keyPair.publicKeyOpenSSH,
    );

    await repository.saveIdentity(tunnelIdentity);

    return ProvisionResult(
      tunnelIdentity: tunnelIdentity,
      publicKeyOpenSSH: keyPair.publicKeyOpenSSH,
    );
  }

  Future<void> _runSetupCommands(SSHClient client, String pubkey) async {
    // Create the user if it doesn't exist; -s /bin/false = no interactive login.
    await _exec(client, 'id $_tunnelUsername || useradd -m -s /bin/false $_tunnelUsername');

    // Set up .ssh directory and authorized_keys.
    await _exec(client, [
      'mkdir -p /home/$_tunnelUsername/.ssh',
      'echo ${_shellQuote(pubkey)} > /home/$_tunnelUsername/.ssh/authorized_keys',
      'chmod 700 /home/$_tunnelUsername/.ssh',
      'chmod 600 /home/$_tunnelUsername/.ssh/authorized_keys',
      'chown -R $_tunnelUsername:$_tunnelUsername /home/$_tunnelUsername/.ssh',
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

  /// Wraps a string in single quotes, escaping any single quotes inside.
  String _shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";
}
