import 'dart:convert';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/tunnel_route.dart';
import '../ssh/route_invite_codec.dart';
import '../storage/route_repository.dart';
import '../storage/server_repository.dart';

/// Turns a base64url route payload received from another device into a stored
/// [TunnelRoute], creating or completing the servers and connections it needs.
///
/// Extracted from the routes screen so the TV shell can reuse it: receiving a
/// route from a phone is the only way a television gets configured.
class ImportRoutePayload {
  const ImportRoutePayload(this._servers, this._routes);

  final ServerRepository _servers;
  final RouteRepository _routes;

  Future<TunnelRoute> call(String encoded) async {
    final bytes = base64Url.decode(encoded);
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final payload = RouteInvitePayload.fromJson(json);

    final existingServers = await _servers.getServers();
    final hops = <RouteHop>[];

    for (final hopData in payload.hops) {
      final server = existingServers.firstWhere(
        (s) => s.host == hopData.host && s.port == hopData.port,
        orElse: () => Server(
          id: '${hopData.host}_${DateTime.now().microsecondsSinceEpoch}',
          host: hopData.host,
          port: hopData.port,
          nickname: hopData.nickname,
        ),
      );
      await _servers.saveServer(server);

      final connection = await _resolveConnection(server, hopData);
      hops.add(RouteHop(serverId: server.id, connectionId: connection.id));
    }

    final route = TunnelRoute(
      id: 'route_${DateTime.now().millisecondsSinceEpoch}',
      label: payload.label,
      hops: hops,
    );
    await _routes.saveRoute(route);
    return route;
  }

  /// Reuses the stored connection for this username, filling in the private
  /// key when the device only held the public half.
  Future<Connection> _resolveConnection(
    Server server,
    RouteHopData hopData,
  ) async {
    final connections = await _servers.getConnections(server.id);

    Connection? existing;
    for (final c in connections) {
      if (c.username == hopData.username) {
        existing = c;
        break;
      }
    }

    if (existing == null) {
      final created = Connection(
        id: '${server.id}_${hopData.username}',
        serverId: server.id,
        label: hopData.username,
        username: hopData.username,
        publicKeyOpenSSH: '',
        privateKeyPem: hopData.privateKeyPem,
        createdAt: DateTime.now(),
      );
      await _servers.saveConnection(created);
      return created;
    }

    if (existing.privateKeyPem == null) {
      final completed = Connection(
        id: existing.id,
        serverId: existing.serverId,
        label: existing.label,
        username: existing.username,
        publicKeyOpenSSH: existing.publicKeyOpenSSH,
        privateKeyPem: hopData.privateKeyPem,
        createdAt: existing.createdAt,
      );
      await _servers.saveConnection(completed);
      return completed;
    }

    return existing;
  }
}
