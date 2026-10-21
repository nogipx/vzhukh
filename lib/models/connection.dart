import 'package:flutter/foundation.dart';

/// Represents one SSH access credential tied to a [Server].
///
/// Each connection corresponds to exactly one authorized_keys entry on the
/// server. One connection = one person = one key pair.
///
/// [privateKeyPem] is only present when this device owns the key (admin's own
/// connection, or an imported invite). For connections created for other people,
/// only [publicKeyOpenSSH] is stored (for revocation).
@immutable
class Connection {
  final String id;
  final String serverId;
  final String label;

  /// authorized_keys line format: "ssh-ed25519 AAAA... label"
  final String publicKeyOpenSSH;

  /// OpenSSH PEM private key. Null when this is a friend's connection
  /// managed by the admin (admin only stores pubkey for revocation).
  final String? privateKeyPem;

  final DateTime createdAt;

  /// Linux username for this connection, e.g. "flume_alice".
  final String username;

  const Connection({
    required this.id,
    required this.serverId,
    required this.label,
    required this.username,
    required this.publicKeyOpenSSH,
    required this.createdAt,
    this.privateKeyPem,
  });

  bool get canConnect => privateKeyPem != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        'label': label,
        'username': username,
        'publicKeyOpenSSH': publicKeyOpenSSH,
        'privateKeyPem': privateKeyPem,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Connection.fromJson(Map<String, dynamic> json) => Connection(
        id: json['id'] as String,
        serverId: json['serverId'] as String,
        label: json['label'] as String,
        username: json['username'] as String,
        publicKeyOpenSSH: json['publicKeyOpenSSH'] as String,
        privateKeyPem: json['privateKeyPem'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}
