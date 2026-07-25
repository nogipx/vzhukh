import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/tunnel_route.dart';
import '../network/local_http_server.dart';
import '../network/payload_transfer.dart';
import '../ssh/route_invite_codec.dart';
import '../storage/server_repository.dart';
import 'scan_qr_screen.dart';

class SendToDeviceScreen extends StatefulWidget {
  final TunnelRoute? _route;
  final Server? _server;
  final Connection? _connection;
  final String? _preEncodedType;
  final String? _preEncoded;

  /// Send a route over the local network.
  const SendToDeviceScreen.route({super.key, required TunnelRoute route})
      : _route = route,
        _server = null,
        _connection = null,
        _preEncodedType = null,
        _preEncoded = null;

  /// Send a single server as a one-hop route.
  ///
  /// An invite is encrypted with a password because it travels out of band to
  /// somebody else. Handing a server to your own television over the local
  /// network is a different matter, and asking for that password on a remote
  /// is precisely what the TV shell exists to avoid — so the server goes as
  /// the one-hop route it already is.
  const SendToDeviceScreen.server({
    super.key,
    required Server server,
    required Connection connection,
  })  : _route = null,
        _server = server,
        _connection = connection,
        _preEncodedType = null,
        _preEncoded = null;

  /// Send an already-encrypted payload (e.g. invite from export screen).
  ///
  /// [server] and [connection] are the material the payload was built from.
  /// Passing them lets the screen fall back to an openable form when the
  /// receiver turns out to be a device that cannot be asked for a password.
  const SendToDeviceScreen.encoded({
    super.key,
    required String type,
    required String encoded,
    Server? server,
    Connection? connection,
  })  : _route = null,
        _server = server,
        _connection = connection,
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

  // Kept so the payload can also be pushed to a device that is listening
  // instead of being fetched from here.
  String? _type;
  String? _encoded;
  bool _pushing = false;

  String get _title {
    if (widget._route != null) return 'Send: ${widget._route!.label}';
    if (widget._server != null) return 'Send: ${widget._server!.nickname}';
    return 'Send to device';
  }

  @override
  void initState() {
    super.initState();
    if (widget._route != null) {
      _prepareRoute();
    } else if (widget._preEncoded != null) {
      // An invite may also carry its source material, so this comes first.
      _startServer(widget._preEncodedType!, widget._preEncoded!);
    } else {
      _prepareServer();
    }
  }

  /// Encodes the server as the one-hop route it already is — the form a
  /// device without a keyboard can open.
  String _encodeAsPlainRoute() {
    final server = widget._server!;
    final connection = widget._connection!;
    final payload = RouteInvitePayload(
      label: server.nickname,
      hops: [
        RouteHopData(
          host: server.host,
          port: server.port,
          nickname: server.nickname,
          username: connection.username,
          privateKeyPem: connection.privateKeyPem!,
        ),
      ],
    );
    return base64Url.encode(
      Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
    );
  }

  Future<void> _prepareServer() async {
    setState(() => _preparing = true);
    try {
      await _startServer('route_plain', _encodeAsPlainRoute());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
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

  void _failed(String message) {
    if (!mounted) return;
    setState(() => _pushing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  /// Pushes to a device that is waiting for a payload — the television, which
  /// cannot scan a code itself. The camera work happens here instead.
  Future<void> _sendToWaitingDevice() async {
    var type = _type;
    var encoded = _encoded;
    if (type == null || encoded == null) return;

    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const ScanQrScreen(
          title: 'Send to TV',
          hint: 'Point the camera at the code on the TV.',
        ),
      ),
    );
    if (raw == null || !mounted) return;

    final DeviceHandshake target;
    try {
      target = DeviceHandshake.parse(raw);
    } catch (_) {
      _failed('That code is not a Vzhukh device.');
      return;
    }

    // A television cannot be asked for a password, so an encrypted invite is
    // useless to it. When the material is at hand, send the openable one-hop
    // route instead of making the viewer deal with a rejection.
    if (target.isTv && type != 'route_plain') {
      if (widget._server == null || widget._connection == null) {
        _failed(
          'A TV cannot open a password protected invite. '
          'Send the server or a route instead.',
        );
        return;
      }
      type = 'route_plain';
      encoded = _encodeAsPlainRoute();
    }

    setState(() => _pushing = true);
    try {
      await const SendPayloadToDevice()(
        target: target,
        type: type,
        encoded: encoded,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sent to TV.')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _pushing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _startServer(String type, String encoded) async {
    _type = type;
    _encoded = encoded;
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
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (!_pushing)
            TextButton.icon(
              onPressed: _sendToWaitingDevice,
              icon: const Icon(Icons.tv),
              label: const Text('Send to TV'),
            ),
        ],
      ),
      body: _pushing
          ? const Center(child: CircularProgressIndicator())
          : _buildQr(),
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
