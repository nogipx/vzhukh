import 'package:flutter/material.dart';

import '../models/app_routing_config.dart';
import '../models/tunnel_route.dart';
import '../storage/route_repository.dart';
import '../storage/server_repository.dart';
import '../vpn/route_resolver.dart';
import '../vpn/vpn_controller.dart';
import 'route_edit_screen.dart';

class RouteListScreen extends StatefulWidget {
  final VpnController vpn;
  final AppRoutingConfig? routing;

  const RouteListScreen({
    super.key,
    required this.vpn,
    this.routing,
  });

  @override
  State<RouteListScreen> createState() => _RouteListScreenState();
}

class _RouteListScreenState extends State<RouteListScreen> {
  final _routeRepo = RouteRepository();
  final _resolver = RouteResolver(ServerRepository());

  List<TunnelRoute> _routes = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final routes = await _routeRepo.getRoutes();
    if (mounted) setState(() => _routes = routes);
  }

  Future<void> _connect(TunnelRoute route) async {
    final List<ResolvedHop> hops;
    try {
      hops = await _resolver.resolve(route);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString()),
        backgroundColor: Colors.red,
      ));
      return;
    }
    await widget.vpn.connect(hops, routing: widget.routing);
  }

  Future<void> _openEdit({TunnelRoute? existing}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RouteEditScreen(existing: existing),
      ),
    );
    await _load();
  }

  Future<void> _delete(TunnelRoute route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete route?'),
        content: Text('Remove "${route.label}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _routeRepo.deleteRoute(route.id);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Routes'), centerTitle: true),
      body: _routes.isEmpty
          ? const Center(
              child: Text(
                'No routes yet.\nTap + to create one.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ListView.builder(
              itemCount: _routes.length,
              itemBuilder: (_, i) {
                final route = _routes[i];
                return _RouteTile(
                  route: route,
                  vpn: widget.vpn,
                  onConnect: () => _connect(route),
                  onEdit: () => _openEdit(existing: route),
                  onDelete: () => _delete(route),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEdit(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _RouteTile extends StatelessWidget {
  final TunnelRoute route;
  final VpnController vpn;
  final VoidCallback onConnect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _RouteTile({
    required this.route,
    required this.vpn,
    required this.onConnect,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hopCount = route.hops.length;
    return ListTile(
      leading: const Icon(Icons.route_outlined),
      title: Text(route.label),
      subtitle: Text(
        hopCount == 1 ? 'Direct (1 hop)' : '$hopCount hops',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder(
            valueListenable: vpn.status,
            builder: (_, status, __) {
              final isActive = status == VpnStatus.connected ||
                  status == VpnStatus.connecting ||
                  status == VpnStatus.reconnecting;
              return IconButton(
                icon: Icon(
                  isActive ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                  color: isActive ? Colors.red : Colors.green,
                ),
                tooltip: isActive ? 'Disconnect' : 'Connect',
                onPressed: isActive ? vpn.disconnect : onConnect,
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') onEdit();
              if (v == 'delete') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(
                value: 'delete',
                child: Text('Delete', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
