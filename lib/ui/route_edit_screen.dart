import 'package:flutter/material.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/tunnel_route.dart';
import '../storage/server_repository.dart';
import '../storage/route_repository.dart';
import '../storage/app_set_repository.dart';
import 'app_set_picker_screen.dart';
import 'common/widgets.dart';
import 'theme/app_theme.dart';

class RouteEditScreen extends StatefulWidget {
  final TunnelRoute? existing;

  const RouteEditScreen({super.key, this.existing});

  @override
  State<RouteEditScreen> createState() => _RouteEditScreenState();
}

/// One hop being edited: an SSH hop picks a server and a connection, a
/// SOCKS5 hop is typed in as host and port.
class _HopEntry {
  final HopType type;
  Server? server;
  Connection? connection;
  final TextEditingController hostCtrl;
  final TextEditingController portCtrl;

  _HopEntry.ssh()
      : type = HopType.ssh,
        hostCtrl = TextEditingController(),
        portCtrl = TextEditingController();

  _HopEntry.socks5(String? host, int? port)
      : type = HopType.socks5,
        hostCtrl = TextEditingController(text: host ?? ''),
        portCtrl = TextEditingController(text: port?.toString() ?? '');

  void dispose() {
    hostCtrl.dispose();
    portCtrl.dispose();
  }

  bool get isComplete => switch (type) {
        HopType.ssh => server != null && connection != null,
        HopType.socks5 =>
          hostCtrl.text.trim().isNotEmpty && int.tryParse(portCtrl.text.trim()) != null,
      };

  String get displayName => switch (type) {
        HopType.ssh => server?.nickname ?? '?',
        HopType.socks5 => '${hostCtrl.text.trim()}:${portCtrl.text.trim()}',
      };
}

class _RouteEditScreenState extends State<RouteEditScreen> {
  final _labelCtrl = TextEditingController();
  final _serverRepo = ServerRepository();
  final _routeRepo = RouteRepository();

  final List<_HopEntry> _hops = [];

  List<Server> _servers = [];
  String? _appSetId;
  String _appSetLabel = 'All apps';
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
      await _setAppSet(widget.existing!.appSetId);
      for (final hop in widget.existing!.hops) {
        if (hop.type == HopType.socks5) {
          if (mounted) {
            setState(() => _hops.add(_HopEntry.socks5(hop.host, hop.port)));
          }
          continue;
        }
        final server = servers.firstWhere((s) => s.id == hop.serverId,
            orElse: () => throw Exception('Server not found'));
        final connections = await _serverRepo.getConnections(hop.serverId!);
        final conn = connections.firstWhere((c) => c.id == hop.connectionId,
            orElse: () => throw Exception('Connection not found'));
        if (mounted) {
          setState(() {
            final entry = _HopEntry.ssh()
              ..server = server
              ..connection = conn;
            _hops.add(entry);
          });
        }
      }
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    for (final hop in _hops) {
      hop.dispose();
    }
    super.dispose();
  }

  Future<List<Connection>> _connectableConnections(String serverId) async {
    final all = await _serverRepo.getConnections(serverId);
    return all.where((c) => c.canConnect).toList();
  }

  Future<void> _addHop() async {
    final type = await showDialog<HopType>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Hop type'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, HopType.ssh),
            child: const ListTile(
              leading: Icon(Icons.terminal),
              title: Text('SSH server'),
              subtitle: Text('Any server you can log into'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, HopType.socks5),
            child: const ListTile(
              leading: Icon(Icons.vpn_lock_outlined),
              title: Text('SOCKS5 proxy'),
              subtitle: Text('A proxy that is already running, e.g. a local port forwarded with ssh -R'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
    if (type == null || !mounted) return;
    setState(() {
      _hops.add(type == HopType.socks5 ? _HopEntry.socks5(null, null) : _HopEntry.ssh());
    });
  }

  Future<void> _pickServer(_HopEntry entry) async {
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
      entry.server = picked;
      entry.connection = null;
    });
  }

  Future<void> _pickConnection(_HopEntry entry) async {
    final server = entry.server;
    if (server == null) return;

    final connections = await _connectableConnections(server.id);
    if (!mounted) return;

    if (connections.isEmpty) {
      showToast(context, 'No connectable connections on this server');
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
      entry.connection = picked;
    });
  }

  Future<void> _save() async {
    final label = _labelCtrl.text.trim();
    if (label.isEmpty) {
      showToast(context, 'Label is required');
      return;
    }
    if (_hops.isEmpty) {
      showToast(context, 'Add at least one hop');
      return;
    }
    for (final hop in _hops) {
      if (!hop.isComplete) {
        showToast(context, switch (hop.type) {
          HopType.ssh => 'Complete all hops: pick a server and a connection',
          HopType.socks5 => 'SOCKS5 hops need a host and a numeric port',
        });
        return;
      }
    }

    setState(() => _saving = true);

    final route = TunnelRoute(
      id: widget.existing?.id ??
          'route_${DateTime.now().millisecondsSinceEpoch}',
      label: label,
      hops: [
        for (final h in _hops)
          switch (h.type) {
            HopType.ssh => RouteHop.ssh(
                serverId: h.server!.id,
                connectionId: h.connection!.id,
              ),
            HopType.socks5 => RouteHop.socks5(
                host: h.hostCtrl.text.trim(),
                port: int.parse(h.portCtrl.text.trim()),
              ),
          },
      ],
      appSetId: _appSetId,
    );

    await _routeRepo.saveRoute(route);
    if (mounted) Navigator.pop(context, route);
  }

  Future<void> _setAppSet(String? id) async {
    final set = await AppSetRepository().find(id);
    if (!mounted) return;
    setState(() {
      _appSetId = set?.id;
      _appSetLabel = set == null ? 'All apps' : '${set.name} · ${describeAppSet(set.config)}';
    });
  }

  Future<void> _openAppPicker() async {
    final choice = await Navigator.push<AppSetChoice>(
      context,
      MaterialPageRoute(builder: (_) => AppSetPickerScreen(selected: _appSetId)),
    );
    if (choice != null) await _setAppSet(choice.id);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final theme = Theme.of(context);

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
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          TextFormField(
            controller: _labelCtrl,
            decoration: const InputDecoration(
              labelText: 'Route label',
              hintText: 'Home server',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Hops', style: theme.textTheme.titleMedium),
              TextButton.icon(
                onPressed: _addHop,
                icon: const Icon(Icons.add),
                label: const Text('Add hop'),
              ),
            ],
          ),
          if (_hops.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Text(
                'No hops yet. Add at least one.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          for (int i = 0; i < _hops.length; i++) ...[
            const SizedBox(height: AppSpacing.sm),
            _HopTile(
              index: i,
              entry: _hops[i],
              onPickServer: () => _pickServer(_hops[i]),
              onPickConnection: () => _pickConnection(_hops[i]),
              onRemove: () => setState(() => _hops.removeAt(i).dispose()),
            ),
          ],
          if (_hops.length > 1) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              'Traffic: this device → ${_hops.map((h) => h.displayName).join(' → ')} → Internet',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.secondary),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          const Divider(),
          const SizedBox(height: AppSpacing.sm),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.apps),
            title: const Text('Apps'),
            subtitle: Text(_appSetLabel),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openAppPicker,
          ),
        ],
      ),
    );
  }
}

class _HopTile extends StatelessWidget {
  final int index;
  final _HopEntry entry;
  final VoidCallback onPickServer;
  final VoidCallback onPickConnection;
  final VoidCallback onRemove;

  const _HopTile({
    required this.index,
    required this.entry,
    required this.onPickServer,
    required this.onPickConnection,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 14,
              child: Text('${index + 1}', style: theme.textTheme.labelMedium),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: switch (entry.type) {
                HopType.socks5 => _Socks5Fields(entry: entry),
                HopType.ssh => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: onPickServer,
                        child: Text(
                          entry.server?.nickname ?? 'Tap to select server',
                          style: TextStyle(
                            color: entry.server == null
                                ? theme.colorScheme.onSurfaceVariant
                                : null,
                            fontWeight: entry.server != null
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (entry.server != null) ...[
                        const SizedBox(height: AppSpacing.xs),
                        GestureDetector(
                          onTap: onPickConnection,
                          child: Text(
                            entry.connection != null
                                ? '${entry.connection!.label} (${entry.connection!.username})'
                                : 'Tap to select connection',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: entry.connection == null
                                  ? AppColors.of(context).warning
                                  : theme.colorScheme.secondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
              },
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

class _Socks5Fields extends StatelessWidget {
  final _HopEntry entry;

  const _Socks5Fields({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: entry.hostCtrl,
          decoration: const InputDecoration(
            labelText: 'SOCKS5 host',
            hintText: '127.0.0.1',
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextFormField(
          controller: entry.portCtrl,
          decoration: const InputDecoration(
            labelText: 'Port',
            hintText: '1080',
            isDense: true,
          ),
          keyboardType: TextInputType.number,
        ),
      ],
    );
  }
}
