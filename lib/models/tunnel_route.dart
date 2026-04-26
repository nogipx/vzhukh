import 'package:flutter/foundation.dart';

import 'app_routing_config.dart';
import 'server.dart';
import 'ssh_identity.dart';

/// One hop in a tunnel chain: references a server and a connection by id.
@immutable
class RouteHop {
  final String serverId;
  final String connectionId;

  const RouteHop({required this.serverId, required this.connectionId});

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'connectionId': connectionId,
      };

  factory RouteHop.fromJson(Map<String, dynamic> json) => RouteHop(
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
  final AppRoutingConfig? routing;

  const TunnelRoute({
    required this.id,
    required this.label,
    required this.hops,
    this.routing,
  });

  bool get isValid => hops.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'hops': hops.map((h) => h.toJson()).toList(),
        if (routing != null) 'routing': routing!.toJson(),
      };

  factory TunnelRoute.fromJson(Map<String, dynamic> json) => TunnelRoute(
        id: json['id'] as String,
        label: json['label'] as String,
        hops: (json['hops'] as List)
            .map((h) => RouteHop.fromJson(Map<String, dynamic>.from(h as Map)))
            .toList(),
        routing: json['routing'] != null
            ? AppRoutingConfig.fromJson(
                Map<String, dynamic>.from(json['routing'] as Map))
            : null,
      );

  TunnelRoute copyWith({
    String? label,
    List<RouteHop>? hops,
    AppRoutingConfig? routing,
    bool clearRouting = false,
  }) =>
      TunnelRoute(
        id: id,
        label: label ?? this.label,
        hops: hops ?? this.hops,
        routing: clearRouting ? null : routing ?? this.routing,
      );
}

/// A resolved hop: actual objects ready for SSH connection.
@immutable
class ResolvedHop {
  final Server server;
  final SshIdentity identity;

  const ResolvedHop({required this.server, required this.identity});
}
