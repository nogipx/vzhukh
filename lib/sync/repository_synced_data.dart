import '../models/app_set.dart';
import '../models/connection.dart';
import '../models/rule_set.dart';
import '../models/server.dart';
import '../models/tunnel_route.dart';
import '../storage/app_set_repository.dart';
import '../storage/plain_store.dart';
import '../storage/route_repository.dart';
import '../storage/rule_set_repository.dart';
import '../storage/server_repository.dart';
import 'share_engine.dart';

/// The app's own things seen as share keys:
///
/// ```
/// server/ID                 a server
/// conn/SERVER_ID/ID         a connection, private key included
/// serverapps/SERVER_ID      the app set a server uses
/// appset/ID                 an Android app set
/// route/ID                  a route
/// ruleset/ID                a macOS rule set
/// ```
///
/// What is device-local stays out: the active rule set, the selected
/// connection, the TV remotes.
class RepositorySyncedData implements SyncedData {
  RepositorySyncedData({
    ServerRepository? servers,
    RouteRepository? routes,
    RuleSetRepository? ruleSets,
    AppSetRepository? appSets,
  })  : _servers = servers ?? ServerRepository(),
        _routes = routes ?? RouteRepository(),
        _ruleSets = ruleSets ?? RuleSetRepository(),
        _appSets = appSets ?? AppSetRepository();

  final ServerRepository _servers;
  final RouteRepository _routes;
  final RuleSetRepository _ruleSets;
  final AppSetRepository _appSets;

  static const _kinds = ['appset', 'server', 'conn', 'serverapps', 'route', 'ruleset'];

  static String _kind(String key) => key.split('/').first;

  @override
  Future<Map<String, Object?>> snapshot() async {
    final out = <String, Object?>{};
    for (final s in await _servers.getServers()) {
      out['server/${s.id}'] = s.toJson();
      for (final c in await _servers.getConnections(s.id)) {
        out['conn/${s.id}/${c.id}'] = c.toJson();
      }
      final link = await plainStore.read(key: '${AppSetRepository.serverLinkPrefix}${s.id}');
      if (link != null) out['serverapps/${s.id}'] = {'appSetId': link};
    }
    for (final r in await _routes.getRoutes()) {
      out['route/${r.id}'] = r.toJson();
    }
    for (final a in await _appSets.getAll()) {
      out['appset/${a.id}'] = a.toJson();
    }
    for (final r in await _ruleSets.getAll()) {
      out['ruleset/${r.id}'] = r.toJson();
    }
    return out;
  }

  @override
  Set<String> closure(Map<String, Object?> snapshot, String item) {
    final keys = <String>{item};
    void appSet(Object? id) {
      if (id is String) keys.add('appset/$id');
    }

    switch (_kind(item)) {
      case 'server':
        final id = item.substring('server/'.length);
        keys.addAll(snapshot.keys.where((k) => k.startsWith('conn/$id/')));
        final link = snapshot['serverapps/$id'];
        if (link is Map) {
          keys.add('serverapps/$id');
          appSet(link['appSetId']);
        }
      case 'route':
        final route = snapshot[item];
        if (route is Map) {
          for (final h in route['hops'] as List? ?? const []) {
            final hop = h as Map;
            keys.add('server/${hop['serverId']}');
            keys.add('conn/${hop['serverId']}/${hop['connectionId']}');
          }
          appSet(route['appSetId']);
        }
    }
    return keys;
  }

  @override
  Future<void> apply(List<MapEntry<String, Object?>> values) async {
    final writes = values.where((e) => e.value != null).toList()
      ..sort((a, b) => _kinds.indexOf(_kind(a.key)).compareTo(_kinds.indexOf(_kind(b.key))));
    // Deletions go the other way round: what refers to a server first.
    final deletes = values.where((e) => e.value == null).toList()
      ..sort((a, b) => _kinds.indexOf(_kind(b.key)).compareTo(_kinds.indexOf(_kind(a.key))));

    // One value this version cannot read is skipped, not the whole batch.
    for (final e in writes) {
      try {
        await _write(e.key, Map<String, dynamic>.from(e.value as Map));
      } catch (_) {}
    }
    for (final e in deletes) {
      try {
        await _delete(e.key);
      } catch (_) {}
    }
  }

  Future<void> _write(String key, Map<String, dynamic> json) async {
    final id = key.substring(key.indexOf('/') + 1);
    switch (_kind(key)) {
      case 'server':
        await _servers.saveServer(Server.fromJson(json));
      case 'conn':
        await _servers.saveConnection(Connection.fromJson(json));
      case 'serverapps':
        await _appSets.setServerSet(id, json['appSetId'] as String?);
      case 'appset':
        await _appSets.save(AppSet.fromJson(json));
      case 'route':
        await _routes.saveRoute(TunnelRoute.fromJson(json));
      case 'ruleset':
        await _ruleSets.save(RuleSet.fromJson(json));
    }
  }

  Future<void> _delete(String key) async {
    final id = key.substring(key.indexOf('/') + 1);
    switch (_kind(key)) {
      case 'server':
        await _servers.deleteServer(id);
      case 'conn':
        final slash = id.indexOf('/');
        final serverId = id.substring(0, slash);
        final connId = id.substring(slash + 1);
        for (final c in await _servers.getConnections(serverId)) {
          if (c.id == connId) await _servers.deleteConnection(c);
        }
      case 'serverapps':
        await _appSets.setServerSet(id, null);
      case 'appset':
        await _appSets.delete(id);
      case 'route':
        await _routes.deleteRoute(id);
      case 'ruleset':
        await _ruleSets.delete(id);
      // Keys of the versions before sets.
      case 'approuting':
        await plainStore.delete(key: 'app_routing_$id');
      case 'rules':
        await plainStore.delete(key: 'routing_rules');
    }
  }
}
