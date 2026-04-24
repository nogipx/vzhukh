import 'package:flutter/material.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/tunnel_route.dart';
import '../storage/server_repository.dart';
import '../storage/route_repository.dart';

class RouteEditScreen extends StatefulWidget {
  final TunnelRoute? existing;

  const RouteEditScreen({super.key, this.existing});

  @override
  State<RouteEditScreen> createState() => _RouteEditScreenState();
}

class _RouteEditScreenState extends State<RouteEditScreen> {
  final _labelCtrl = TextEditingController();
  final _serverRepo = ServerRepository();
  final _routeRepo = RouteRepository();

  // Each hop is (server, connection) — both nullable while being picked.
  final List<({Server? server, Connection? connection})> _hops = [];

  List<Server> _servers = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final servers = await _serverRepo.getServers();
    if (mounted) setState(() => _servers = servers);

    if (widget.existing != null) {
      _labelCtrl.text = widget.existing!.label;
      for (final hop in widget.existing!.hops) {
        final server = servers.firstWhere((s) => s.id == hop.serverId,
            orElse: () => throw Exception('Server not found'));
        final connections = await _serverRepo.getConnections(hop.serverId);
        final conn = connections.firstWhere((c) => c.id == hop.connectionId,
            orElse: () => throw Exception('Connection not found'));
        if (mounted) {
          setState(() => _hops.add((server: server, connection: conn)));
        }
      }
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<List<Connection>> _connectableConnections(String serverId) async {
    final all = await _serverRepo.getConnections(serverId);
    return all.where((c) => c.canConnect).toList();
  }

  Future<void> _pickServer(int index) async {
    if (_servers.isEmpty) return;

    final picked = await showDialog<Server>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Select server'),
        children: _servers
            .map((s) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, s),
                  child: ListTile(
                    title: Text(s.nickname),
                    subtitle: Text('${s.host}:${s.port}'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ))
            .toList(),
      ),
    );
    if (picked == null) return;

    setState(() {
      _hops[index] = (server: picked, connection: null);
    });
  }

  Future<void> _pickConnection(int index) async {
    final server = _hops[index].server;
    if (server == null) return;

    final connections = await _connectableConnections(server.id);
    if (!mounted) return;

    if (connections.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No connectable connections on this server'),
      ));
      return;
    }

    final picked = await showDialog<Connection>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Select connection'),
        children: connections
            .map((c) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, c),
                  child: ListTile(
                    title: Text(c.label),
                    subtitle: Text(c.username),
                    contentPadding: EdgeInsets.zero,
                  ),
                ))
            .toList(),
      ),
    );
    if (picked == null) return;

    setState(() {
      _hops[index] = (server: server, connection: picked);
    });
  }

  Future<void> _save() async {
    final label = _labelCtrl.text.trim();
    if (label.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Label is required')));
      return;
    }
    if (_hops.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Add at least one hop')));
      return;
    }
    for (final hop in _hops) {
      if (hop.server == null || hop.connection == null) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Complete all hops')));
        return;
      }
    }

    setState(() => _saving = true);

    final route = TunnelRoute(
      id: widget.existing?.id ??
          'route_${DateTime.now().millisecondsSinceEpoch}',
      label: label,
      hops: _hops
          .map((h) => RouteHop(
                serverId: h.server!.id,
                connectionId: h.connection!.id,
              ))
          .toList(),
    );

    await _routeRepo.saveRoute(route);
    if (mounted) Navigator.pop(context, route);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit route' : 'New route'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _labelCtrl,
            decoration: const InputDecoration(
              labelText: 'Route label',
              hintText: 'Home VPN',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Hops', style: Theme.of(context).textTheme.titleMedium),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _hops.add((server: null, connection: null))),
                icon: const Icon(Icons.add),
                label: const Text('Add hop'),
              ),
            ],
          ),
          if (_hops.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No hops yet. Add at least one.',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          for (int i = 0; i < _hops.length; i++) ...[
            const SizedBox(height: 8),
            _HopTile(
              index: i,
              hop: _hops[i],
              onPickServer: () => _pickServer(i),
              onPickConnection: () => _pickConnection(i),
              onRemove: () => setState(() => _hops.removeAt(i)),
            ),
          ],
          if (_hops.length > 1) ...[
            const SizedBox(height: 12),
            Text(
              'Traffic: this device → ${_hops.map((h) => h.server?.nickname ?? '?').join(' → ')} → Internet',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HopTile extends StatelessWidget {
  final int index;
  final ({Server? server, Connection? connection}) hop;
  final VoidCallback onPickServer;
  final VoidCallback onPickConnection;
  final VoidCallback onRemove;

  const _HopTile({
    required this.index,
    required this.hop,
    required this.onPickServer,
    required this.onPickConnection,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              child: Text('${index + 1}',
                  style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: onPickServer,
                    child: Text(
                      hop.server?.nickname ?? 'Tap to select server',
                      style: TextStyle(
                        color: hop.server == null ? Colors.grey : null,
                        fontWeight: hop.server != null
                            ? FontWeight.w500
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  if (hop.server != null) ...[
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: onPickConnection,
                      child: Text(
                        hop.connection != null
                            ? '${hop.connection!.label} (${hop.connection!.username})'
                            : 'Tap to select connection',
                        style: TextStyle(
                          fontSize: 12,
                          color: hop.connection == null
                              ? Colors.orange
                              : Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
