import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../models/server.dart';
import '../models/ssh_identity.dart';
import 'ssh_client_factory.dart';

/// An SSH connection to a server as its administrator, for running shell
/// commands. Logging in costs a key exchange and a password check, so a
/// screen that runs several commands keeps one open and closes it when it
/// is done.
class AdminShell {
  AdminShell._(this._socket, this._client);

  final SSHSocket _socket;
  final SSHClient _client;

  /// Connects and logs in.
  static Future<AdminShell> open(Server server, SshIdentity admin) async {
    final socket = await SSHSocket.connect(server.host, server.port);
    final client = buildSshClient(
      socket,
      username: admin.username,
      password: admin.password,
      identities: admin.privateKeyPem != null ? [...SSHKeyPair.fromPem(admin.privateKeyPem!)] : null,
    );
    try {
      await client.authenticated;
    } catch (_) {
      client.close();
      rethrow;
    }
    return AdminShell._(socket, client);
  }

  bool get isClosed => _client.isClosed;

  /// Runs [command] and returns what it printed. Throws when it fails.
  Future<String> run(String command) async {
    final session = await _client.execute(command);
    final out = await utf8.decodeStream(session.stdout);
    await session.done;
    final code = session.exitCode;
    if (code != null && code != 0) {
      throw Exception('Remote command failed (exit $code): ${command.split('\n').first}');
    }
    return out;
  }

  Future<void> close() async {
    _client.close();
    try {
      await _socket.done;
    } catch (_) {}
  }

  /// [s] as one word for the shell.
  static String quote(String s) => "'${s.replaceAll("'", "'\\''")}'";
}

/// Logs in to [server] as its administrator, runs [body], logs out. For a
/// single operation; a screen doing several keeps an [AdminShell] open.
class WithAdminShell {
  const WithAdminShell();

  Future<T> call<T>(Server server, SshIdentity admin, Future<T> Function(AdminShell shell) body) async {
    final shell = await AdminShell.open(server, admin);
    try {
      return await body(shell);
    } finally {
      await shell.close();
    }
  }
}
