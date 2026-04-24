import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  bool _preparing = false;
  String? _error;

  HttpServer? _server;
  String? _ip;
  int? _port;
  bool _delivered = false;

  String get _title =>
      widget._route != null ? 'Send: ${widget._route!.label}' : 'Send to device';

  @override
  void initState() {
    super.initState();
    if (widget._route != null) {
      _prepareRoute();
    } else {
      _startServer(widget._preEncodedType!, widget._preEncoded!);
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  Future<void> _prepareRoute() async {
    setState(() => _preparing = true);
    try {
      final hops = await _buildHopData();
      final payload = RouteInvitePayload(
        label: widget._route!.label,
        hops: hops,
      );
      final encoded = base64Url.encode(
        Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
      );
      await _startServer('route_plain', encoded);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
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
    if (_preparing) {
      return Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _buildQr(),
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
