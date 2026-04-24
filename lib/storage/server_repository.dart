import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/connection.dart';
import '../models/server.dart';

class ServerRepository {
  static const _storage = FlutterSecureStorage();
  static const _serversKey = 'servers_v2';

  static String _connectionsKey(String serverId) => 'connections_$serverId';

  // ---- Servers ----

  Future<List<Server>> getServers() async {
    final raw = await _storage.read(key: _serversKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Server.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> saveServer(Server server) async {
    final servers = await getServers();
    final idx = servers.indexWhere((s) => s.id == server.id);
    if (idx >= 0) {
      servers[idx] = server;
    } else {
      servers.add(server);
    }
    await _storage.write(key: _serversKey, value: jsonEncode(servers.map((s) => s.toJson()).toList()));
  }

  Future<void> deleteServer(String serverId) async {
    final servers = await getServers();
    servers.removeWhere((s) => s.id == serverId);
    await _storage.write(key: _serversKey, value: jsonEncode(servers.map((s) => s.toJson()).toList()));
    await _storage.delete(key: _connectionsKey(serverId));
  }

  // ---- Connections ----

  Future<List<Connection>> getConnections(String serverId) async {
    final raw = await _storage.read(key: _connectionsKey(serverId));
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Connection.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> saveConnection(Connection connection) async {
    final connections = await getConnections(connection.serverId);
    final idx = connections.indexWhere((c) => c.id == connection.id);
    if (idx >= 0) {
      connections[idx] = connection;
    } else {
      connections.add(connection);
    }
    await _storage.write(
      key: _connectionsKey(connection.serverId),
      value: jsonEncode(connections.map((c) => c.toJson()).toList()),
    );
  }

  Future<void> deleteConnection(Connection connection) async {
    final connections = await getConnections(connection.serverId);
    connections.removeWhere((c) => c.id == connection.id);
    await _storage.write(
      key: _connectionsKey(connection.serverId),
      value: jsonEncode(connections.map((c) => c.toJson()).toList()),
    );
  }

  /// Returns the first connection on this device that can connect (has private key).
  Future<Connection?> getOwnConnection(String serverId) async {
    final connections = await getConnections(serverId);
    try {
      return connections.firstWhere((c) => c.canConnect);
    } catch (_) {
      return null;
    }
  }
}
