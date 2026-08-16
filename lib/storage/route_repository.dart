import 'dart:convert';
import '../models/tunnel_route.dart';
import 'secure_store.dart';

class RouteRepository {
  static const _key = 'tunnel_routes';

  Future<List<TunnelRoute>> getRoutes() async {
    final raw = await secureStore.read(key: _key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => TunnelRoute.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> saveRoute(TunnelRoute route) async {
    final routes = await getRoutes();
    final idx = routes.indexWhere((r) => r.id == route.id);
    if (idx >= 0) {
      routes[idx] = route;
    } else {
      routes.add(route);
    }
    await secureStore.write(
      key: _key,
      value: jsonEncode(routes.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> deleteRoute(String id) async {
    final routes = await getRoutes();
    routes.removeWhere((r) => r.id == id);
    await secureStore.write(
      key: _key,
      value: jsonEncode(routes.map((r) => r.toJson()).toList()),
    );
  }
}
