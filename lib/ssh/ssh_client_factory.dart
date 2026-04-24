import 'package:dartssh2/dartssh2.dart';

/// Creates an [SSHClient] that supports both 'password' and
/// 'keyboard-interactive' auth methods with the same password.
///
/// Many servers (Ubuntu in particular) use keyboard-interactive even when
/// the user expects plain password auth. Providing both callbacks ensures
/// authentication succeeds regardless of server configuration.
SSHClient buildSshClient(
  SSHSocket socket, {
  required String username,
  String? password,
  List<SSHKeyPair>? identities,
}) {
  return SSHClient(
    socket,
    username: username,
    onPasswordRequest: password != null ? () => password : null,
    onUserInfoRequest: password != null
        ? (request) =>
            List.filled(request.prompts.length, password)
        : null,
    identities: identities,
  );
}
