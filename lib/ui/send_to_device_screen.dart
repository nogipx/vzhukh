import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/tunnel_route.dart';
import '../network/local_http_server.dart';
import '../ssh/route_invite_codec.dart';
import '../storage/server_repository.dart';

class SendToDeviceScreen extends StatefulWidget {
  final TunnelRoute? _route;
  final String? _preEncodedType;
  final String? _preEncoded;

  /// Send a route: builds hop data and encrypts with a password.
  const SendToDeviceScreen.route({super.key, required TunnelRoute route})
      : _route = route,
        _preEncodedType = null,
        _preEncoded = null;

  /// Send an already-encrypted payload (e.g. invite generated in export screen).
  const SendToDeviceScreen.encoded({
    super.key,
    required String type,
    required String encoded,
  })  : _route = null,
        _preEncodedType = type,
        _preEncoded = encoded;

  @override
  State<SendToDeviceScreen> createState() => _SendToDeviceScreenState();
}

class _SendToDeviceScreenState extends State<SendToDeviceScreen> {
  final _repo = ServerRepository();
  final _codec = const RouteInviteCodec();
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _obscurePass = true;
  bool _sending = false;
  String? _error;
  _ScannedTarget? _target;

  bool get _needsPassword => widget._route != null;

  String get _title => widget._route != null
      ? 'Send: ${widget._route!.label}'
      : 'Send to device';

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _onBarcodeDetected(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final ip = json['ip'] as String;
      final port = json['port'] as int;
      setState(() => _target = _ScannedTarget(ip: ip, port: port));
    } catch (_) {
      // not a valid target QR — keep scanning
    }
  }

  Future<List<RouteHopData>> _buildHopData() async {
    final hops = <RouteHopData>[];
    for (final hop in widget._route!.hops) {
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
    if (_needsPassword && !_formKey.currentState!.validate()) return;
    final target = _target!;

    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      final String type;
      final String encoded;

      if (widget._route != null) {
        final hopData = await _buildHopData();
        final payload = RouteInvitePayload(
          label: widget._route!.label,
          hops: hopData,
        );
        encoded = _codec.encode(payload, _passwordCtrl.text);
        type = 'route';
      } else {
        type = widget._preEncodedType!;
        encoded = widget._preEncoded!;
      }

      await LocalHttpServer.sendTo(
        host: target.ip,
        port: target.port,
        type: type,
        payload: encoded,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sent! Enter the password on the receiving device.'),
          ),
        );
        Navigator.pop(context);
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
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (_target != null)
            TextButton(
              onPressed: () => setState(() => _target = null),
              child: const Text('Rescan'),
            ),
        ],
      ),
      body: _target == null ? _buildScanner() : _buildForm(),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(onDetect: _onBarcodeDetected),
        const Positioned(
          bottom: 40,
          left: 0,
          right: 0,
          child: Center(
            child: Text(
              'Scan the QR on the receiving device',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildForm() {
    final target = _target!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green),
                  const SizedBox(width: 8),
                  Text(
                    '${target.ip}:${target.port}',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            if (_needsPassword) ...[
              const SizedBox(height: 24),
              TextFormField(
                controller: _passwordCtrl,
                obscureText: _obscurePass,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Encryption password',
                  hintText: 'Tell this password to the receiver',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePass
                        ? Icons.visibility
                        : Icons.visibility_off),
                    onPressed: () =>
                        setState(() => _obscurePass = !_obscurePass),
                  ),
                ),
                validator: (v) => v == null || v.isEmpty ? 'Required' : null,
              ),
            ],
            const SizedBox(height: 24),
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.red)),
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
    );
  }
}

class _ScannedTarget {
  final String ip;
  final int port;

  const _ScannedTarget({required this.ip, required this.port});
}
