import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class ReceivedPayload {
  final String type; // 'route' | 'invite'
  final String data; // base64url encoded encrypted blob

  const ReceivedPayload({required this.type, required this.data});
}

/// Runs a tiny HTTP server on [port] to receive encrypted payloads
/// pushed from other devices running this app.
///
/// POST /push  body: {type: "route"|"invite", payload: base64url string}
class LocalHttpServer {
  static const int port = 8765;

  final ValueNotifier<ReceivedPayload?> received = ValueNotifier(null);

  HttpServer? _server;

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handle, onError: (_) {}, cancelOnError: false);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'POST' && request.uri.path == '/push') {
      try {
        final body = await utf8.decodeStream(request);
        final json = jsonDecode(body) as Map<String, dynamic>;
        final type = json['type'] as String?;
        final payload = json['payload'] as String?;

        if (type != null && payload != null) {
          received.value = ReceivedPayload(type: type, data: payload);
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..write('ok');
      } catch (_) {
        request.response.statusCode = HttpStatus.badRequest;
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }

  /// Returns the first non-loopback IPv4 address, or null if not connected.
  static Future<String?> localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Sends an encrypted payload to another device.
  static Future<void> sendTo({
    required String host,
    required String type,
    required String payload,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .postUrl(Uri.parse('http://$host:$port/push'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'type': type, 'payload': payload}));
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Device responded with ${response.statusCode}');
      }
    } finally {
      client.close();
    }
  }
}
