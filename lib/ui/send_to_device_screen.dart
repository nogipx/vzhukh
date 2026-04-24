import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/tunnel_route.dart';
import '../network/local_http_server.dart';
import '../ssh/route_invite_codec.dart';
import '../storage/server_repository.dart';

class SendToDeviceScreen extends StatefulWidget {
  final TunnelRoute? _route;
  final String? _preEncodedType;
  final String? _preEncoded;

  /// Send a route: encrypts with a password entered by the user.
  const SendToDeviceScreen.route({super.key, required TunnelRoute route})
      : _route = route,
        _preEncodedType = null,
        _preEncoded = null;

  /// Send an already-encrypted payload (e.g. invite from export screen).
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
  bool _preparing = false;
  String? _error;

  // Set once server is started.
  HttpServer? _server;
  String? _ip;
  int? _port;
  bool _delivered = false;

  bool get _needsPassword => widget._route != null;
  bool get _serving => _server != null;

  String get _title =>
      widget._route != null ? 'Send: ${widget._route!.label}' : 'Send to device';

  @override
  void initState() {
    super.initState();
    // Pre-encoded mode: start serving immediately.
    if (!_needsPassword) {
      _startServer(widget._preEncodedType!, widget._preEncoded!);
    }
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _server?.close(force: true);
    super.dispose();
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

  Future<void> _prepare() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final hopData = await _buildHopData();
      final payload = RouteInvitePayload(
        label: widget._route!.label,
        hops: hopData,
      );
      final encoded = _codec.encode(payload, _passwordCtrl.text);
      await _startServer('route', encoded);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _startServer(String type, String encoded) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final ip = await LocalHttpServer.localIp();
    if (!mounted) {
      await server.close(force: true);
      return;
    }
    setState(() {
      _server = server;
      _ip = ip;
      _port = server.port;
    });

    final responseBody = jsonEncode({'type': type, 'payload': encoded});

    server.listen(
      (request) async {
        if (request.method == 'GET' && request.uri.path == '/payload') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(responseBody);
          await request.response.close();
          if (mounted && !_delivered) {
            setState(() => _delivered = true);
            await server.close(force: true);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Delivered successfully.')),
              );
              Navigator.pop(context);
            }
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _serving ? _buildQr() : _buildPasswordForm(),
    );
  }

  Widget _buildPasswordForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Choose a password to encrypt the route. '
              'You will need to tell it to the receiver.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _passwordCtrl,
              obscureText: _obscurePass,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Encryption password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscurePass ? Icons.visibility : Icons.visibility_off),
                  onPressed: () =>
                      setState(() => _obscurePass = !_obscurePass),
                ),
              ),
              validator: (v) => v == null || v.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 24),
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: _preparing ? null : _prepare,
              child: _preparing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Generate QR'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQr() {
    final qrData = jsonEncode({'ip': _ip, 'port': _port});
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Scan this QR on the receiving device.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: qrData,
                version: QrVersions.auto,
                size: 260,
                errorCorrectionLevel: QrErrorCorrectLevel.L,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_ip:$_port',
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.grey),
            ),
            const SizedBox(height: 24),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('Waiting for receiving device...'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
