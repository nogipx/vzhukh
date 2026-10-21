import 'dart:convert';

import '../models/ssh_identity.dart';
import '../models/tunnel_route.dart';
import '../storage/route_repository.dart';
import '../storage/plain_store.dart';
import '../storage/server_repository.dart';
import '../sync/received_items.dart';
import 'route_resolver.dart';

/// What the user pressed Connect on: a saved route, or one connection of one
/// server. Kept so the app can rebuild the daemon's config after a restart,
/// when the tunnel is still up but the hops it was given are long gone from
/// memory.
class ConnectionRef {
  final String? routeId;
  final String? serverId;
  final String? connectionId;
  final String label;

  const ConnectionRef.route(String this.routeId, {required this.label})
      : serverId = null,
        connectionId = null;

  const ConnectionRef.server(
    String this.serverId,
    String this.connectionId, {
    required this.label,
  }) : routeId = null;

  const ConnectionRef._(this.routeId, this.serverId, this.connectionId, this.label);

  Map<String, dynamic> toJson() => {
        if (routeId != null) 'routeId': routeId,
        if (serverId != null) 'serverId': serverId,
        if (connectionId != null) 'connectionId': connectionId,
        'label': label,
      };

  factory ConnectionRef.fromJson(Map<String, dynamic> json) => ConnectionRef._(
        json['routeId'] as String?,
        json['serverId'] as String?,
        json['connectionId'] as String?,
        json['label'] as String? ?? '',
      );
}

class ConnectionRefStore {
  static const _key = 'macos_connected_ref';

  Future<ConnectionRef?> load() async {
    final raw = await plainStore.read(key: _key);
    if (raw == null) return null;
    return ConnectionRef.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
  }

  Future<void> save(ConnectionRef ref) =>
      plainStore.write(key: _key, value: jsonEncode(ref.toJson()));

  Future<void> clear() => plainStore.delete(key: _key);
}

/// Turns a [ConnectionRef] back into hops.
class ResolveConnectionRef {
  final ServerRepository _servers;
  final RouteRepository _routes;

  const ResolveConnectionRef(this._servers, this._routes);

  Future<List<ResolvedHop>> call(ConnectionRef ref) async {
    if (ref.routeId != null) {
      final routes = await _routes.getRoutes();
      final route = routes.where((r) => r.id == ref.routeId).firstOrNull ??
          ReceivedItems.instance.route(ref.routeId!) ??
          (throw Exception('Route "${ref.label}" is not available'));
      return RouteResolver(_servers).resolve(route);
    }

    final servers = await _servers.getServers();
    final server = servers.where((s) => s.id == ref.serverId).firstOrNull ??
        ReceivedItems.instance.server(ref.serverId!) ??
        (throw Exception('Server "${ref.label}" is not available'));
    final connections = [
      ...await _servers.getConnections(server.id),
      ...ReceivedItems.instance.connections(server.id),
    ];
    final connection = connections.firstWhere(
      (c) => c.id == ref.connectionId,
      orElse: () => throw Exception('Connection of "${ref.label}" no longer exists'),
    );
    return [
      ResolvedHop(
        server: server,
        identity: SshIdentity(
          id: connection.id,
          serverId: connection.serverId,
          username: connection.username,
          authType: SshAuthType.privateKey,
          isAdmin: false,
          privateKeyPem: connection.privateKeyPem,
        ),
      ),
    ];
  }
}
