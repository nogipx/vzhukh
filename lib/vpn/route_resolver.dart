import '../models/ssh_identity.dart';
import '../models/tunnel_route.dart';
import '../storage/server_repository.dart';

/// Resolves a [TunnelRoute] into a list of [ResolvedHop] by loading
/// the actual Server and Connection objects from storage.
class RouteResolver {
  final ServerRepository _repo;

  const RouteResolver(this._repo);

  Future<List<ResolvedHop>> resolve(TunnelRoute route) async {
    final resolved = <ResolvedHop>[];

    for (final hop in route.hops) {
      final servers = await _repo.getServers();
      final server = servers.firstWhere(
        (s) => s.id == hop.serverId,
        orElse: () => throw Exception(
            'Server ${hop.serverId} not found'),
      );

      final connections = await _repo.getConnections(hop.serverId);
      final connection = connections.firstWhere(
        (c) => c.id == hop.connectionId,
        orElse: () => throw Exception(
            'Connection ${hop.connectionId} not found'),
      );

      if (!connection.canConnect) {
        throw Exception(
            'Connection "${connection.label}" has no private key on this device');
      }

      resolved.add(ResolvedHop(
        server: server,
        identity: SshIdentity(
          id: connection.id,
          serverId: connection.serverId,
          username: connection.username,
          authType: SshAuthType.privateKey,
          isAdmin: false,
          privateKeyPem: connection.privateKeyPem,
        ),
      ));
    }

    return resolved;
  }
}
