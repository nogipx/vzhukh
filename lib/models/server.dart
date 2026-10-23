import 'package:flutter/foundation.dart';

@immutable
class Server {
  final String id;
  final String host;
  final int port;
  final String nickname;

  /// IPv4 resolvers the phone's DNS goes to when traffic leaves through this
  /// server, queried from the server's side; empty for [defaultDnsServers].
  /// A resolver only this server reaches (a work VPN's, say) works here.
  final List<String> dnsServers;

  static const defaultDnsServers = ['8.8.8.8', '8.8.4.4'];

  const Server({
    required this.id,
    required this.host,
    required this.port,
    required this.nickname,
    this.dnsServers = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'host': host,
        'port': port,
        'nickname': nickname,
        if (dnsServers.isNotEmpty) 'dns': dnsServers,
      };

  factory Server.fromJson(Map<String, dynamic> json) => Server(
        id: json['id'] as String,
        host: json['host'] as String,
        port: json['port'] as int,
        nickname: json['nickname'] as String,
        dnsServers: (json['dns'] as List?)?.cast<String>() ?? const [],
      );

  Server copyWith({String? host, int? port, String? nickname, List<String>? dnsServers}) => Server(
        id: id,
        host: host ?? this.host,
        port: port ?? this.port,
        nickname: nickname ?? this.nickname,
        dnsServers: dnsServers ?? this.dnsServers,
      );
}
