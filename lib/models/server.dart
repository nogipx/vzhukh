import 'package:flutter/foundation.dart';

@immutable
class Server {
  final String id;
  final String host;
  final int port;
  final String nickname;

  const Server({
    required this.id,
    required this.host,
    required this.port,
    required this.nickname,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'host': host,
        'port': port,
        'nickname': nickname,
      };

  factory Server.fromJson(Map<String, dynamic> json) => Server(
        id: json['id'] as String,
        host: json['host'] as String,
        port: json['port'] as int,
        nickname: json['nickname'] as String,
      );

  Server copyWith({String? host, int? port, String? nickname}) => Server(
        id: id,
        host: host ?? this.host,
        port: port ?? this.port,
        nickname: nickname ?? this.nickname,
      );
}
