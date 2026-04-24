import 'package:flutter/material.dart';

import '../models/tunnel_route.dart';
import '../network/local_http_server.dart';
import '../ssh/route_invite_codec.dart';
import '../storage/server_repository.dart';

class SendToDeviceScreen extends StatefulWidget {
  final TunnelRoute route;

  const SendToDeviceScreen({super.key, required this.route});

  @override
  State<SendToDeviceScreen> createState() => _SendToDeviceScreenState();
}

class _SendToDeviceScreenState extends State<SendToDeviceScreen> {
  final _repo = ServerRepository();
  final _codec = const RouteInviteCodec();
  final _ipCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _obscurePass = true;
  bool _sending = false;
  String? _error;
  String? _successMessage;

  @override
  void dispose() {
    _ipCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<List<RouteHopData>> _buildHopData() async {
    final hops = <RouteHopData>[];
    for (final hop in widget.route.hops) {
      final servers = await _repo.getServers();
      final server = servers.firstWhere(
        (s) => s.id == hop.serverId,
        orElse: () => throw Exception('Server not found'),
      );
      final connections = await _repo.getConnections(hop.serverId);
      final conn = connections.firstWhere(
        (c) => c.id == hop.connectionId,
        orElse: () => throw Exception('Connection not found'),
      );
      if (!conn.canConnect) {
        throw Exception(
          '"${server.nickname}" — connection "${conn.label}" '
          'has no private key on this device.',
        );
      }
      hops.add(RouteHopData(
        host: server.host,
        port: server.port,
        nickname: server.nickname,
        username: conn.username,
        privateKeyPem: conn.privateKeyPem!,
      ));
    }
    return hops;
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _sending = true;
      _error = null;
      _successMessage = null;
    });

    try {
      final hopData = await _buildHopData();
      final payload = RouteInvitePayload(
        label: widget.route.label,
        hops: hopData,
      );
      final encoded = _codec.encode(payload, _passwordCtrl.text);
      await LocalHttpServer.sendTo(
        host: _ipCtrl.text.trim(),
        type: 'route',
        payload: encoded,
      );
      if (mounted) {
        setState(() => _successMessage = 'Sent! Enter the password on the receiving device.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Send: ${widget.route.label}')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Send this route to another device running Vzhukh on the same network. '
                'Enter the receiving device\'s IP address (shown in its Routes screen).',
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _ipCtrl,
                decoration: const InputDecoration(
                  labelText: 'Device IP address',
                  hintText: '192.168.1.x',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.tv),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordCtrl,
                obscureText: _obscurePass,
                decoration: InputDecoration(
                  labelText: 'Encryption password',
                  hintText: 'Tell this password to the receiver',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscurePass ? Icons.visibility : Icons.visibility_off),
                    onPressed: () =>
                        setState(() => _obscurePass = !_obscurePass),
                  ),
                ),
                validator: (v) =>
                    v == null || v.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 24),
              if (_error != null) ...[
                Text(_error!, style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 12),
              ],
              if (_successMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green),
                  ),
                  child: Text(_successMessage!,
                      style: const TextStyle(color: Colors.green)),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton.icon(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send),
                label: const Text('Send'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
