import 'package:flutter/material.dart';

import '../models/app_routing_config.dart';
import '../models/tunnel_route.dart';
import '../network/local_http_server.dart';
import '../storage/route_repository.dart';
import '../storage/server_repository.dart';
import '../vpn/route_resolver.dart';
import '../vpn/vpn_controller.dart';
import 'export_route_screen.dart';
import 'import_invite_screen.dart';
import 'import_route_screen.dart';
import 'network_receive_screen.dart';
import 'route_edit_screen.dart';
import 'send_to_device_screen.dart';

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

  Future<void> _receiveFromDevice() async {
    final payload = await Navigator.push<ReceivedPayload>(
      context,
      MaterialPageRoute(builder: (_) => const NetworkReceiveScreen()),
    );
    if (payload == null || !mounted) return;

    if (payload.type == 'route') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImportRouteScreen(prefilled: payload.data),
        ),
      );
      await _load();
    } else if (payload.type == 'invite') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImportInviteScreen(prefilled: payload.data),
        ),
      );
    }
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
      MaterialPageRoute(builder: (_) => RouteEditScreen(existing: existing)),
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
      appBar: AppBar(
        title: const Text('Routes'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.wifi),
            tooltip: 'Receive from device',
            onPressed: _receiveFromDevice,
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Import via QR',
            onPressed: () async {
              final imported = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const ImportRouteScreen()),
              );
              if (imported == true) await _load();
            },
          ),
        ],
      ),
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
                  onExport: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ExportRouteScreen(route: route),
                    ),
                  ),
                  onSend: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SendToDeviceScreen.route(route: route),
                    ),
                  ),
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
  final VoidCallback onExport;
  final VoidCallback onSend;

  const _RouteTile({
    required this.route,
    required this.vpn,
    required this.onConnect,
    required this.onEdit,
    required this.onDelete,
    required this.onExport,
    required this.onSend,
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
                  isActive
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline,
                  color: isActive ? Colors.red : Colors.green,
                ),
                tooltip: isActive ? 'Disconnect' : 'Connect',
                onPressed: isActive ? vpn.disconnect : onConnect,
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'send') onSend();
              if (v == 'export') onExport();
              if (v == 'edit') onEdit();
              if (v == 'delete') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'send', child: Text('Send to device')),
              PopupMenuItem(value: 'export', child: Text('Share via QR')),
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
