import 'package:dartssh2/dartssh2.dart';

/// Creates an [SSHClient] that supports both 'password' and
/// 'keyboard-interactive' auth methods with the same password.
///
/// Many servers (Ubuntu in particular) use keyboard-interactive even when
/// the user expects plain password auth. Providing both callbacks ensures
/// authentication succeeds regardless of server configuration.
///
/// [keepAliveInterval] is dartssh2's own keepalive, whose ping has no reply
/// timeout: it notices nothing on a connection that went silent. The tunnel
/// turns it off and probes the chain itself.
SSHClient buildSshClient(
  SSHSocket socket, {
  required String username,
  String? password,
  List<SSHKeyPair>? identities,
  Duration? keepAliveInterval = const Duration(seconds: 10),
}) {
  return SSHClient(
    socket,
    username: username,
    keepAliveInterval: keepAliveInterval,
    onPasswordRequest: password != null ? () => password : null,
    onUserInfoRequest: password != null
        ? (request) =>
            List.filled(request.prompts.length, password)
        : null,
    identities: identities,
  );
}
