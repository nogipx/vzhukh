import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// SSHSocket implementation that tunnels SSH bytes through a WebSocket.
/// The server side (e.g. Caddy) must proxy WebSocket → SSH port.
class WebSocketSSHSocket implements SSHSocket {
  final WebSocketChannel _channel;
  final StreamController<Uint8List> _streamController;

  WebSocketSSHSocket._(this._channel)
      : _streamController = StreamController<Uint8List>() {
    _channel.stream.listen(
      (data) {
        if (data is List<int>) {
          _streamController.add(Uint8List.fromList(data));
        }
      },
      onError: _streamController.addError,
      onDone: _streamController.close,
    );
  }

  static Future<WebSocketSSHSocket> connect(
    Uri uri, {
    bool skipTlsVerify = false,
  }) async {
    final WebSocketChannel channel;
    if (skipTlsVerify && uri.scheme == 'wss') {
      final httpClient = HttpClient()
        ..badCertificateCallback = (_, __, ___) => true;
      final ws = await WebSocket.connect(
        uri.toString(),
        customClient: httpClient,
      );
      channel = IOWebSocketChannel(ws);
    } else {
      channel = WebSocketChannel.connect(uri);
      await channel.ready;
    }
    return WebSocketSSHSocket._(channel);
  }

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  @override
  StreamSink<List<int>> get sink => _channel.sink as StreamSink<List<int>>;

  @override
  Future<void> get done => _channel.sink.done;

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }

  @override
  void destroy() {
    _channel.sink.close();
    _streamController.close();
  }
}
