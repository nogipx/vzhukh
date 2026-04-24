import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/app_routing_config.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../storage/server_repository.dart';
import '../vpn/vpn_controller.dart';
import 'app_picker_screen.dart';

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

  SshIdentity? _tunnelIdentity;
  AppRoutingConfig _routing = const AppRoutingConfig.empty();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final identity = await _repo.getTunnelIdentity(widget.server.id);

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
        _tunnelIdentity = identity;
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
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(initial: _routing),
      ),
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
    if (_tunnelIdentity == null) return;
    await _vpn.connect(widget.server, _tunnelIdentity!, routing: _routing);
  }

  @override
  void dispose() {
    _vpn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.server;

    return Scaffold(
      appBar: AppBar(title: Text(server.nickname)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusCard(vpn: _vpn),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: Text('${server.host}:${server.port}'),
              subtitle: const Text('Host'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.vpn_key_outlined),
              title: Text(_tunnelIdentity != null ? 'Provisioned' : 'Not provisioned'),
              subtitle: const Text('SSH key'),
            ),
            if (Platform.isAndroid) ...[
              const Divider(),
              _AppRoutingTile(routing: _routing, onTap: _openAppPicker),
            ],
            const SizedBox(height: 24),
            if (_tunnelIdentity == null)
              const Text(
                'Server is not provisioned. Go back and re-add the server.',
                style: TextStyle(color: Colors.orange),
                textAlign: TextAlign.center,
              )
            else
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
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(isConnected ? Icons.stop : Icons.play_arrow),
                    label: Text(
                      isConnected
                          ? 'Disconnect'
                          : status == VpnStatus.reconnecting
                              ? 'Reconnecting...'
                              : isConnecting
                                  ? 'Connecting...'
                                  : 'Connect',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: isConnected ? Colors.red : null,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  );
                },
              ),
          ],
        ),
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
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: color),
                ),
                if (status == VpnStatus.error)
                  ValueListenableBuilder(
                    valueListenable: vpn.errorMessage,
                    builder: (_, msg, __) => msg != null
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              msg,
                              style: const TextStyle(
                                  color: Colors.red, fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
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
