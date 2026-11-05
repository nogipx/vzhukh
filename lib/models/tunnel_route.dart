import 'package:flutter/foundation.dart';

import 'app_routing_config.dart';
import 'server.dart';
import 'ssh_identity.dart';

/// What a route hop speaks.
enum HopType { ssh, socks5 }

/// One hop in a tunnel chain. An SSH hop references a server and a
/// connection by id; a SOCKS5 hop is just a host and a port — e.g. a local
/// port reverse-forwarded from someone else's machine (ssh -R), which lets
/// their traffic exit through this device.
@immutable
class RouteHop {
  final HopType type;
  final String? serverId;
  final String? connectionId;
  final String? host;
  final int? port;

  const RouteHop.ssh({required this.serverId, required this.connectionId})
      : type = HopType.ssh,
        host = null,
        port = null;

  const RouteHop.socks5({required this.host, required this.port})
      : type = HopType.socks5,
        serverId = null,
        connectionId = null;

  bool get isValid => switch (type) {
        HopType.ssh => serverId != null && connectionId != null,
        HopType.socks5 => host != null && host!.isNotEmpty && port != null,
      };

  Map<String, dynamic> toJson() => {
        'type': type.name,
        if (serverId != null) 'serverId': serverId,
        if (connectionId != null) 'connectionId': connectionId,
        if (host != null) 'host': host,
        if (port != null) 'port': port,
      };

  factory RouteHop.fromJson(Map<String, dynamic> json) =>
      json['type'] == 'socks5'
          ? RouteHop.socks5(
              host: json['host'] as String,
              port: json['port'] as int,
            )
          : RouteHop.ssh(
              serverId: json['serverId'] as String,
              connectionId: json['connectionId'] as String,
            );
}

/// A route is an ordered list of hops.
/// Single-hop = plain tunnel. Multi-hop = chained SSH tunnel.
@immutable
class TunnelRoute {
  final String id;
  final String label;
  final List<RouteHop> hops;

  /// The app set ([AppSet]) deciding which Android apps use this route;
  /// null for all of them.
  final String? appSetId;

  /// The app list as routes kept it before app sets. Read only to move it
  /// into a set (MigrateToSets).
  final AppRoutingConfig? routing;

  const TunnelRoute({
    required this.id,
    required this.label,
    required this.hops,
    this.appSetId,
    this.routing,
  });

  bool get isValid => hops.isNotEmpty && hops.every((h) => h.isValid);

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'hops': hops.map((h) => h.toJson()).toList(),
        if (appSetId != null) 'appSetId': appSetId,
        if (routing != null) 'routing': routing!.toJson(),
      };

  factory TunnelRoute.fromJson(Map<String, dynamic> json) => TunnelRoute(
        id: json['id'] as String,
        label: json['label'] as String,
        hops: (json['hops'] as List)
            .map((h) => RouteHop.fromJson(Map<String, dynamic>.from(h as Map)))
            .toList(),
        appSetId: json['appSetId'] as String?,
        routing: json['routing'] != null
            ? AppRoutingConfig.fromJson(
                Map<String, dynamic>.from(json['routing'] as Map))
            : null,
      );

  TunnelRoute copyWith({
    String? label,
    List<RouteHop>? hops,
    String? appSetId,
    bool clearAppSet = false,
    bool clearRouting = false,
  }) =>
      TunnelRoute(
        id: id,
        label: label ?? this.label,
        hops: hops ?? this.hops,
        appSetId: clearAppSet ? null : appSetId ?? this.appSetId,
        routing: clearRouting ? null : routing,
      );
}

/// A resolved hop: ready to connect. SSH hops carry the server and identity;
/// SOCKS5 hops carry just an address.
@immutable
class ResolvedHop {
  final HopType type;
  final Server? server;
  final SshIdentity? identity;
  final String? host;
  final int? port;

  const ResolvedHop.ssh({required this.server, required this.identity})
      : type = HopType.ssh,
        host = null,
        port = null;

  const ResolvedHop.socks5({required this.host, required this.port})
      : type = HopType.socks5,
        server = null,
        identity = null;

  String get displayName => switch (type) {
        HopType.ssh => server!.nickname,
        HopType.socks5 => '${host!}:${port ?? 1080}',
      };
}
