import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/tunnel_route.dart';
import '../ssh/route_invite_codec.dart';
import '../storage/server_repository.dart';

class ExportRouteScreen extends StatefulWidget {
  final TunnelRoute route;

  const ExportRouteScreen({super.key, required this.route});

  @override
  State<ExportRouteScreen> createState() => _ExportRouteScreenState();
}

class _ExportRouteScreenState extends State<ExportRouteScreen> {
  final _repo = ServerRepository();
  final _codec = const RouteInviteCodec();
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _obscurePass = true;
  bool _loading = true;
  String? _encoded;
  String? _error;

  List<RouteHopData>? _hopData;

  @override
  void initState() {
    super.initState();
    _loadHops();
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadHops() async {
    try {
      final hops = <RouteHopData>[];
      for (final hop in widget.route.hops) {
        final servers = await _repo.getServers();
        final server = servers.firstWhere(
          (s) => s.id == hop.serverId,
          orElse: () => throw Exception('Server not found: ${hop.serverId}'),
        );
        final connections = await _repo.getConnections(hop.serverId);
        final conn = connections.firstWhere(
          (c) => c.id == hop.connectionId,
          orElse: () =>
              throw Exception('Connection not found: ${hop.connectionId}'),
        );
        if (!conn.canConnect) {
          throw Exception(
            'Hop "${server.nickname}" — connection "${conn.label}" '
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
      if (mounted) {
        setState(() {
          _hopData = hops;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  bool _generating = false;

  Future<void> _generate() async {
    if (!_formKey.currentState!.validate()) return;
    if (_hopData == null) return;
    setState(() {
      _error = null;
      _generating = true;
    });
    try {
      final payload = RouteInvitePayload(
        label: widget.route.label,
        hops: _hopData!,
      );
      final encoded = await _codec.encodeAsync(payload, _passwordCtrl.text);
      if (mounted) setState(() => _encoded = encoded);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Export: ${widget.route.label}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null && _hopData == null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red),
                      ),
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  ] else ...[
                    Text(
                      'Encrypts all ${_hopData!.length} hop(s) with a password. '
                      'Share the QR and the password separately.',
                      style: const TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 24),
                    Form(
                      key: _formKey,
                      child: TextFormField(
                        controller: _passwordCtrl,
                        obscureText: _obscurePass,
                        decoration: InputDecoration(
                          labelText: 'Route password',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(_obscurePass
                                ? Icons.visibility
                                : Icons.visibility_off),
                            onPressed: () =>
                                setState(() => _obscurePass = !_obscurePass),
                          ),
                        ),
                        validator: (v) =>
                            v == null || v.isEmpty ? 'Required' : null,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _generating ? null : _generate,
                      child: _generating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Generate QR'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!,
                          style: const TextStyle(color: Colors.red)),
                    ],
                    if (_encoded != null) ...[
                      const SizedBox(height: 32),
                      Center(
                        child: Container(
                          color: Colors.white,
                          padding: const EdgeInsets.all(12),
                          child: QrImageView(
                            data: _encoded!,
                            version: QrVersions.auto,
                            size: 280,
                            errorCorrectionLevel: QrErrorCorrectLevel.L,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _encoded!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Copied to clipboard')),
                          );
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy route code'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
    );
  }
}
