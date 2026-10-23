import 'dart:io';
import 'package:flutter/material.dart';

import '../models/app_set.dart';
import '../models/connection.dart';
import '../models/server.dart';
import '../storage/server_repository.dart';
import '../storage/admin_credentials.dart';
import '../storage/app_set_repository.dart';
import '../sync/sync_signal.dart';
import 'admin_access.dart';
import 'app_set_picker_screen.dart';
import 'server_access_screen.dart';
import 'theme/app_theme.dart';

class ServerDetailScreen extends StatefulWidget {
  final Server server;

  const ServerDetailScreen({super.key, required this.server});

  @override
  State<ServerDetailScreen> createState() => _ServerDetailScreenState();
}

class _ServerDetailScreenState extends State<ServerDetailScreen> {

  final _repo = ServerRepository();

  late Server _server;

  List<Connection> _connections = [];
  final _appSets = AppSetRepository();
  bool _adminSaved = false;
  AppSet? _appSet;

  @override
  void initState() {
    super.initState();
    _server = widget.server;
    _load();
    SyncSignal.instance.remote.addListener(_load);
  }

  @override
  void dispose() {
    SyncSignal.instance.remote.removeListener(_load);
    super.dispose();
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _server.nickname);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename server'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nickname'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.isNotEmpty) Navigator.pop(ctx, v);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final updated = _server.copyWith(nickname: result);
    await _repo.saveServer(updated);
    if (mounted) setState(() => _server = updated);
  }

  Future<void> _editDns() async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _DnsDialog(initial: _server.dnsServers),
    );
    if (result == null) return;
    final updated = _server.copyWith(dnsServers: result);
    await _repo.saveServer(updated);
    if (mounted) setState(() => _server = updated);
  }

  Future<void> _load() async {
    final connections = await _repo.getConnections(widget.server.id);

    final appSet = await _appSets.find(await _appSets.serverSet(widget.server.id));
    final adminSaved = await const AdminCredentials().has(widget.server.id);

    if (mounted) {
      setState(() {
        _connections = connections;
        _appSet = appSet;
        _adminSaved = adminSaved;
      });
    }
  }

  Future<void> _toggleSavedAdmin() async {
    if (_adminSaved) {
      await const AdminCredentials().forget(widget.server.id);
    } else {
      // Asked with "Remember" offered; nothing connects yet.
      await obtainAdminIdentity(context, widget.server);
    }
    await _load();
  }

  Future<void> _openAppPicker() async {
    final choice = await Navigator.push<AppSetChoice>(
      context,
      MaterialPageRoute(builder: (_) => AppSetPickerScreen(selected: _appSet?.id)),
    );
    if (choice == null) return;
    await _appSets.setServerSet(widget.server.id, choice.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_server.nickname),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Rename',
            onPressed: _rename,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          if (Platform.isAndroid) ...[
            _AppRoutingTile(appSet: _appSet, onTap: _openAppPicker),
            const Divider(),
          ],
          if (Platform.isAndroid || Platform.isIOS) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: const Text('DNS servers'),
              subtitle: Text(_server.dnsServers.isEmpty
                  ? '${Server.defaultDnsServers.join(', ')} (default)'
                  : _server.dnsServers.join(', ')),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editDns,
            ),
            const Divider(),
          ],
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Admin password'),
            subtitle: Text(_adminSaved
                ? 'Saved on this device, unlocked with fingerprint, face or PIN'
                : 'Asked each time it is needed'),
            trailing: TextButton(
              onPressed: _toggleSavedAdmin,
              child: Text(_adminSaved ? 'Forget' : 'Save…'),
            ),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.group_outlined),
            title: const Text('Access'),
            subtitle: Text(_connections.isEmpty
                ? 'Who can use this server, read from the server'
                : '${_connections.length} known on this device; the full list is on the server'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ServerAccessScreen(server: widget.server)),
              );
              await _load();
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _AppRoutingTile extends StatelessWidget {
  final AppSet? appSet;
  final VoidCallback onTap;

  const _AppRoutingTile({required this.appSet, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final set = appSet;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.apps),
      title: const Text('Apps'),
      subtitle: Text(set == null ? 'All apps' : '${set.name} · ${describeAppSet(set.config)}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// Asks for the resolvers as IPv4 addresses separated by commas or spaces;
/// empty means the defaults.
class _DnsDialog extends StatefulWidget {
  final List<String> initial;

  const _DnsDialog({required this.initial});

  @override
  State<_DnsDialog> createState() => _DnsDialogState();
}

class _DnsDialogState extends State<_DnsDialog> {
  late final _ctrl = TextEditingController(text: widget.initial.join(', '));
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final servers = _ctrl.text.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList();
    final bad = servers.where((s) => InternetAddress.tryParse(s)?.type != InternetAddressType.IPv4);
    if (bad.isNotEmpty) {
      setState(() => _error = 'Not an IPv4 address: ${bad.first}');
      return;
    }
    Navigator.pop(context, servers);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('DNS servers'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.text,
        decoration: InputDecoration(
          hintText: Server.defaultDnsServers.join(', '),
          helperText: 'Queried through this server, also when it is the last hop of a route. Empty for the defaults',
          helperMaxLines: 2,
          errorText: _error,
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
