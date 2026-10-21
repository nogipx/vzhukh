import 'dart:convert';

import '../models/app_routing_config.dart';
import '../models/app_set.dart';
import 'app_set_repository.dart';
import 'plain_store.dart';
import 'route_repository.dart';
import 'server_repository.dart';

/// Moves app lists kept inside routes and next to servers into app sets the
/// route or server points at. Runs once; the rules move into a set by
/// themselves (RuleSetRepository).
class MigrateToSets {
  const MigrateToSets();

  static const _doneKey = 'migrated_app_sets';
  static const _legacyServerPrefix = 'app_routing_';

  Future<void> call() async {
    if (await plainStore.read(key: _doneKey) != null) return;
    final sets = AppSetRepository();
    var n = 0;
    String id() => '${AppSetRepository.newId()}_${n++}';

    final routes = RouteRepository();
    for (final route in await routes.getRoutes()) {
      final routing = route.routing;
      if (routing == null) continue;
      String? setId;
      if (routing.packages.isNotEmpty) {
        setId = id();
        await sets.save(AppSet(id: setId, name: '${route.label} apps', config: routing));
      }
      await routes.saveRoute(route.copyWith(appSetId: setId, clearRouting: true));
    }

    final servers = ServerRepository();
    for (final server in await servers.getServers()) {
      final key = '$_legacyServerPrefix${server.id}';
      final raw = await plainStore.read(key: key);
      if (raw == null) continue;
      try {
        final routing = AppRoutingConfig.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
        if (routing.packages.isNotEmpty) {
          final setId = id();
          await sets.save(AppSet(id: setId, name: '${server.nickname} apps', config: routing));
          await sets.setServerSet(server.id, setId);
        }
      } catch (_) {}
      await plainStore.delete(key: key);
    }

    await plainStore.write(key: _doneKey, value: '1');
  }
}
