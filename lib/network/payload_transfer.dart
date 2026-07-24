import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'local_http_server.dart';

/// Receives a payload pushed by another device over the local network.
///
/// The existing transfer has the sender host the payload and the receiver scan
/// a QR code to fetch it. A television has no camera and typing an address on
/// a remote is miserable, so for that direction the roles are swapped: the TV
/// listens and shows its own address, and the phone — which does have a camera
/// — scans it and pushes.
class PayloadReceiver {
  HttpServer? _server;
  final _received = Completer<ReceivedPayload>();

  String? _ip;
  int? _port;

  String? get ip => _ip;
  int? get port => _port;

  /// Completes when a device pushes a payload.
  Future<ReceivedPayload> get received => _received.future;

  /// The contents of the QR code the sending device scans.
  String get handshake => jsonEncode({'ip': _ip, 'port': _port});

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _ip = await LocalHttpServer.localIp();
    _port = server.port;

    server.listen(
      _handle,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method != 'POST' || request.uri.path != '/payload') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    try {
      final body = await utf8.decodeStream(request);
      final json = jsonDecode(body) as Map<String, dynamic>;
      final payload = ReceivedPayload(
        type: json['type'] as String,
        data: json['payload'] as String,
      );

      request.response.statusCode = HttpStatus.ok;
      await request.response.close();

      if (!_received.isCompleted) _received.complete(payload);
    } catch (e) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}

/// Pushes a payload to a device that is waiting with a [PayloadReceiver].
class SendPayloadToDevice {
  const SendPayloadToDevice();

  /// [handshake] is the JSON carried by the receiver's QR code.
  Future<void> call({
    required String handshake,
    required String type,
    required String encoded,
  }) async {
    final target = jsonDecode(handshake) as Map<String, dynamic>;
    final ip = target['ip'] as String;
    final port = target['port'] as int;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request =
          await client.postUrl(Uri.parse('http://$ip:$port/payload'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'type': type, 'payload': encoded}));

      final response = await request.close();
      await response.drain<void>();

      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Receiver replied ${response.statusCode}');
      }
    } finally {
      client.close();
    }
  }
}
