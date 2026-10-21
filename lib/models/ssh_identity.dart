import 'package:flutter/foundation.dart';

enum SshAuthType { password, privateKey }

/// An SSH credential tied to a [Server].
///
/// [isAdmin] = true  → used only for one-time provisioning (root / sudo user).
/// [isAdmin] = false → used for tunnel connections (the 'flume' user).
@immutable
class SshIdentity {
  final String id;
  final String serverId;
  final String username;
  final SshAuthType authType;

  /// Only present when [authType] == [SshAuthType.password].
  final String? password;

  /// OpenSSH PEM private key. Present when [authType] == [SshAuthType.privateKey].
  final String? privateKeyPem;

  /// Public key in authorized_keys format: "ssh-ed25519 AAAA... comment".
  final String? publicKeyOpenSSH;

  final bool isAdmin;

  const SshIdentity({
    required this.id,
    required this.serverId,
    required this.username,
    required this.authType,
    required this.isAdmin,
    this.password,
    this.privateKeyPem,
    this.publicKeyOpenSSH,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        'username': username,
        'authType': authType.name,
        'isAdmin': isAdmin,
        'password': password,
        'privateKeyPem': privateKeyPem,
        'publicKeyOpenSSH': publicKeyOpenSSH,
      };

  factory SshIdentity.fromJson(Map<String, dynamic> json) => SshIdentity(
        id: json['id'] as String,
        serverId: json['serverId'] as String,
        username: json['username'] as String,
        authType: SshAuthType.values.byName(json['authType'] as String),
        isAdmin: json['isAdmin'] as bool,
        password: json['password'] as String?,
        privateKeyPem: json['privateKeyPem'] as String?,
        publicKeyOpenSSH: json['publicKeyOpenSSH'] as String?,
      );

  SshIdentity copyWith({
    String? password,
    String? privateKeyPem,
    String? publicKeyOpenSSH,
    SshAuthType? authType,
  }) =>
      SshIdentity(
        id: id,
        serverId: serverId,
        username: username,
        authType: authType ?? this.authType,
        isAdmin: isAdmin,
        password: password ?? this.password,
        privateKeyPem: privateKeyPem ?? this.privateKeyPem,
        publicKeyOpenSSH: publicKeyOpenSSH ?? this.publicKeyOpenSSH,
      );
}
