import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/app_routing_config.dart';
import '../models/connection.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../ssh/connection_manager.dart';
import '../storage/server_repository.dart';
import '../vpn/vpn_controller.dart';
import 'app_picker_screen.dart';
import 'export_invite_screen.dart';

class ServerDetailScreen extends StatefulWidget {
  final Server server;

  const ServerDetailScreen({super.key, required this.server});

  @override
  State<ServerDetailScreen> createState() => _ServerDetailScreenState();
}

class _ServerDetailScreenState extends State<ServerDetailScreen> {
  static const _storage = FlutterSecureStorage();
  static const _routingKeyPrefix = 'app_routing_';

  final _repo = ServerRepository();
  final _vpn = VpnController();

  List<Connection> _connections = [];
  Connection? _activeConnection;
  AppRoutingConfig _routing = const AppRoutingConfig.empty();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final connections = await _repo.getConnections(widget.server.id);
    final own = connections.where((c) => c.canConnect).firstOrNull;

    final rawRouting =
        await _storage.read(key: '$_routingKeyPrefix${widget.server.id}');
    AppRoutingConfig routing = const AppRoutingConfig.empty();
    if (rawRouting != null) {
      try {
        routing = AppRoutingConfig.fromJson(
          Map<String, dynamic>.from(jsonDecode(rawRouting) as Map),
        );
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _connections = connections;
        _activeConnection = own;
        _routing = routing;
      });
    }
  }

  Future<void> _saveRouting(AppRoutingConfig routing) async {
    await _storage.write(
      key: '$_routingKeyPrefix${widget.server.id}',
      value: jsonEncode(routing.toJson()),
    );
  }

  Future<void> _openAppPicker() async {
    final result = await Navigator.push<AppRoutingConfig>(
      context,
      MaterialPageRoute(builder: (_) => AppPickerScreen(initial: _routing)),
    );
    if (result != null) {
      setState(() => _routing = result);
      await _saveRouting(result);
    }
  }

  Future<void> _toggle() async {
    final status = _vpn.status.value;
    if (status == VpnStatus.connected || status == VpnStatus.reconnecting) {
      await _vpn.disconnect();
      return;
    }
    if (_activeConnection == null) return;
    await _vpn.connect(widget.server, _activeConnection!, routing: _routing);
  }

  Future<void> _showAddConnectionDialog() async {
    final labelCtrl = TextEditingController();
    final userCtrl = TextEditingController(text: 'root');
    final passCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool obscure = true;

    final result = await showDialog<(String, SshIdentity)?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add connection'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: labelCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      hintText: 'Alice\'s phone',
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: userCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Admin username'),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: passCtrl,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: 'Admin password',
                      suffixIcon: IconButton(
                        icon: Icon(
                            obscure ? Icons.visibility : Icons.visibility_off),
                        onPressed: () =>
                            setDialogState(() => obscure = !obscure),
                      ),
                    ),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required' : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                final admin = SshIdentity(
                  id: 'admin_temp',
                  serverId: widget.server.id,
                  username: userCtrl.text.trim(),
                  authType: SshAuthType.password,
                  isAdmin: true,
                  password: passCtrl.text,
                );
                Navigator.pop(ctx, (labelCtrl.text.trim(), admin));
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return;
    final (label, adminIdentity) = result;

    final addConnection = AddConnection(_repo);

    Connection? newConnection;
    String? error;

    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _WorkingDialog(
        label: 'Adding connection...',
        future: addConnection(widget.server, adminIdentity, label).then((c) {
          newConnection = c;
        }).catchError((e) {
          error = e.toString();
        }),
        onDone: () => Navigator.pop(ctx),
      ),
    );

    await _load();

    if (!mounted) return;

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $error'), backgroundColor: Colors.red),
      );
      return;
    }

    if (newConnection != null) {
      // Offer to export invite immediately.
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ExportInviteScreen(
            server: widget.server,
            connection: newConnection!,
          ),
        ),
      );
    }
  }

  Future<void> _revokeConnection(Connection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke access?'),
        content: Text(
            '"${connection.label}" will no longer be able to connect.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Revoke', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Ask for admin credentials.
    final adminIdentity = await _promptAdminCredentials();
    if (adminIdentity == null) return;

    if (!mounted) return;
    String? error;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _WorkingDialog(
        label: 'Revoking...',
        future: RevokeConnection(_repo)(widget.server, adminIdentity, connection)
            .catchError((e) {
          error = e.toString();
        }),
        onDone: () => Navigator.pop(ctx),
      ),
    );

    await _load();

    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $error'), backgroundColor: Colors.red),
      );
    }
  }

  Future<SshIdentity?> _promptAdminCredentials() async {
    final userCtrl = TextEditingController(text: 'root');
    final passCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool obscure = true;

    return showDialog<SshIdentity>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Admin credentials'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: userCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Admin username'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: passCtrl,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: 'Admin password',
                    suffixIcon: IconButton(
                      icon: Icon(
                          obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () =>
                          setDialogState(() => obscure = !obscure),
                    ),
                  ),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Required' : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(
                  ctx,
                  SshIdentity(
                    id: 'admin_temp',
                    serverId: widget.server.id,
                    username: userCtrl.text.trim(),
                    authType: SshAuthType.password,
                    isAdmin: true,
                    password: passCtrl.text,
                  ),
                );
              },
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _vpn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.server.nickname)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(vpn: _vpn),
          const SizedBox(height: 8),
          if (Platform.isAndroid) ...[
            _AppRoutingTile(routing: _routing, onTap: _openAppPicker),
            const Divider(),
          ],
          if (_activeConnection != null) ...[
            const SizedBox(height: 8),
            ValueListenableBuilder(
              valueListenable: _vpn.status,
              builder: (context, status, _) {
                final isConnecting = status == VpnStatus.connecting ||
                    status == VpnStatus.reconnecting;
                final isConnected = status == VpnStatus.connected;
                return FilledButton.icon(
                  onPressed: isConnecting ? null : _toggle,
                  icon: isConnecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(isConnected ? Icons.stop : Icons.play_arrow),
                  label: Text(isConnected
                      ? 'Disconnect'
                      : status == VpnStatus.reconnecting
                          ? 'Reconnecting...'
                          : isConnecting
                              ? 'Connecting...'
                              : 'Connect'),
                  style: FilledButton.styleFrom(
                    backgroundColor: isConnected ? Colors.red : null,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Connections',
                  style: Theme.of(context).textTheme.titleMedium),
              TextButton.icon(
                onPressed: _showAddConnectionDialog,
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ],
          ),
          if (_connections.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No connections.',
                  style: TextStyle(color: Colors.grey)),
            )
          else
            ..._connections.map((c) => _ConnectionTile(
                  connection: c,
                  server: widget.server,
                  onRevoke: () => _revokeConnection(c),
                )),
        ],
      ),
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  final Connection connection;
  final Server server;
  final VoidCallback onRevoke;

  const _ConnectionTile({
    required this.connection,
    required this.server,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        connection.canConnect ? Icons.vpn_key : Icons.key_off_outlined,
        color: connection.canConnect ? null : Colors.grey,
      ),
      title: Text(connection.label),
      subtitle: Text(
        connection.canConnect ? 'This device' : 'External',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (connection.canConnect)
            IconButton(
              icon: const Icon(Icons.qr_code),
              tooltip: 'Export invite',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ExportInviteScreen(
                    server: server,
                    connection: connection,
                  ),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Revoke',
            onPressed: onRevoke,
          ),
        ],
      ),
    );
  }
}

class _WorkingDialog extends StatefulWidget {
  final String label;
  final Future<void> future;
  final VoidCallback onDone;

  const _WorkingDialog({
    required this.label,
    required this.future,
    required this.onDone,
  });

  @override
  State<_WorkingDialog> createState() => _WorkingDialogState();
}

class _WorkingDialogState extends State<_WorkingDialog> {
  @override
  void initState() {
    super.initState();
    widget.future.whenComplete(widget.onDone);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Text(widget.label),
        ],
      ),
    );
  }
}

class _AppRoutingTile extends StatelessWidget {
  final AppRoutingConfig routing;
  final VoidCallback onTap;

  const _AppRoutingTile({required this.routing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final count = routing.packages.length;
    final subtitle = count == 0
        ? 'All apps through tunnel'
        : '${routing.mode == AppRoutingMode.whitelist ? 'Only' : 'Except'} $count app${count == 1 ? '' : 's'}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.apps),
      title: const Text('App routing'),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _StatusCard extends StatelessWidget {
  final VpnController vpn;

  const _StatusCard({required this.vpn});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: vpn.status,
      builder: (context, status, _) {
        final (icon, label, color) = switch (status) {
          VpnStatus.disconnected =>
            (Icons.wifi_off, 'Disconnected', Colors.grey),
          VpnStatus.connecting =>
            (Icons.hourglass_top, 'Connecting...', Colors.orange),
          VpnStatus.connected =>
            (Icons.verified_user, 'Connected', Colors.green),
          VpnStatus.reconnecting =>
            (Icons.sync, 'Reconnecting...', Colors.orange),
          VpnStatus.error => (Icons.error_outline, 'Error', Colors.red),
        };
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Icon(icon, size: 48, color: color),
                const SizedBox(height: 8),
                Text(label,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: color)),
                if (status == VpnStatus.error)
                  ValueListenableBuilder(
                    valueListenable: vpn.errorMessage,
                    builder: (_, msg, __) => msg != null
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(msg,
                                style: const TextStyle(
                                    color: Colors.red, fontSize: 12),
                                textAlign: TextAlign.center),
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
