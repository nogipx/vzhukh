import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../network/local_http_server.dart';

class NetworkReceiveScreen extends StatefulWidget {
  const NetworkReceiveScreen({super.key});

  @override
  State<NetworkReceiveScreen> createState() => _NetworkReceiveScreenState();
}

class _NetworkReceiveScreenState extends State<NetworkReceiveScreen> {
  HttpServer? _server;
  String? _ip;
  int? _port;
  bool _waiting = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  Future<void> _start() async {
    try {
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
      _listen(server);
    } catch (e) {
      if (mounted) setState(() => _waiting = false);
    }
  }

  void _listen(HttpServer server) {
    server.listen(
      (request) async {
        if (request.method == 'POST' && request.uri.path == '/push') {
          try {
            final body = await utf8.decodeStream(request);
            final json = jsonDecode(body) as Map<String, dynamic>;
            final type = json['type'] as String?;
            final payload = json['payload'] as String?;
            request.response..statusCode = HttpStatus.ok..write('ok');
            await request.response.close();
            if (type != null && payload != null && mounted) {
              Navigator.pop(
                context,
                ReceivedPayload(type: type, data: payload),
              );
            }
          } catch (_) {
            request.response.statusCode = HttpStatus.badRequest;
            await request.response.close();
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
    final ready = _ip != null && _port != null;
    final qrData = ready ? jsonEncode({'ip': _ip, 'port': _port}) : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Receive from device')),
      body: Center(
        child: ready
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Scan this QR on the sending device.',
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(
                        data: qrData!,
                        version: QrVersions.auto,
                        size: 260,
                        errorCorrectionLevel: QrErrorCorrectLevel.L,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '$_ip:$_port',
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: Colors.grey,
                      ),
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
                        Text('Waiting for incoming data...'),
                      ],
                    ),
                  ],
                ),
              )
            : _waiting
                ? const CircularProgressIndicator()
                : const Text('Failed to start receiver'),
      ),
    );
  }
}
