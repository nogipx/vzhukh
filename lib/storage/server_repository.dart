import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';

class ServerRepository {
  static const _storage = FlutterSecureStorage();
  static const _serversKey = 'servers_v2';

  static String _identitiesKey(String serverId) => 'identities_$serverId';

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
    await _storage.delete(key: _identitiesKey(serverId));
  }

  // ---- Identities ----

  Future<List<SshIdentity>> getIdentities(String serverId) async {
    final raw = await _storage.read(key: _identitiesKey(serverId));
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => SshIdentity.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> saveIdentity(SshIdentity identity) async {
    final identities = await getIdentities(identity.serverId);
    final idx = identities.indexWhere((i) => i.id == identity.id);
    if (idx >= 0) {
      identities[idx] = identity;
    } else {
      identities.add(identity);
    }
    await _storage.write(
      key: _identitiesKey(identity.serverId),
      value: jsonEncode(identities.map((i) => i.toJson()).toList()),
    );
  }

  Future<void> deleteIdentity(SshIdentity identity) async {
    final identities = await getIdentities(identity.serverId);
    identities.removeWhere((i) => i.id == identity.id);
    await _storage.write(
      key: _identitiesKey(identity.serverId),
      value: jsonEncode(identities.map((i) => i.toJson()).toList()),
    );
  }

  /// Returns the tunnel identity (non-admin, key auth) for a server, if provisioned.
  Future<SshIdentity?> getTunnelIdentity(String serverId) async {
    final identities = await getIdentities(serverId);
    try {
      return identities.firstWhere(
        (i) => !i.isAdmin && i.authType == SshAuthType.privateKey,
      );
    } catch (_) {
      return null;
    }
  }
}
