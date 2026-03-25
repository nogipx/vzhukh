import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import '../models/server_config.dart';

/// Opens an SSH connection and runs a SOCKS5 proxy on localhost:2080.
/// This is the Dart equivalent of `ssh -D 2080 user@host`.
class SshTunnel {
  static const int socksPort = 2080;

  final ServerConfig config;
  final void Function()? onDisconnected;

  SSHClient? _client;
  ServerSocket? _socksServer;
  bool _running = false;

  SshTunnel(this.config, {this.onDisconnected});

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;

    final socket = await SSHSocket.connect(config.host, config.port);

    _client = SSHClient(
      socket,
      username: config.username,
      onPasswordRequest: config.password != null
          ? () => config.password!
          : null,
      identities: config.privateKey != null
          ? [
              ...SSHKeyPair.fromPem(config.privateKey!),
            ]
          : null,
    );

    // Wait for authentication to complete.
    await _client!.authenticated;

    // Start SOCKS5 proxy server that forwards through SSH dynamic forwarding.
    _socksServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      socksPort,
      shared: false,
    );

    _running = true;
    _acceptLoop();
  }

  void _acceptLoop() {
    _socksServer?.listen(
      _handleSocksClient,
      onError: (_) {},
      onDone: () {
        _running = false;
        onDisconnected?.call();
      },
    );
  }

  Future<void> _handleSocksClient(Socket client) async {
    final reader = _BufferedReader(client);
    try {
      // Read SOCKS5 greeting: version + nmethods
      final greeting = await reader.read(2);
      if (greeting[0] != 5) return;
      await reader.read(greeting[1]); // consume auth methods
      client.add([5, 0]); // no auth

      // Read request header
      final req = await reader.read(4);
      if (req[0] != 5 || req[1] != 1) {
        client.add([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
        return;
      }

      String host;
      final atyp = req[3];
      if (atyp == 1) {
        final addr = await reader.read(4);
        host = addr.join('.');
      } else if (atyp == 3) {
        final len = (await reader.read(1))[0];
        host = String.fromCharCodes(await reader.read(len));
      } else if (atyp == 4) {
        host = '[${_formatIpv6(await reader.read(16))}]';
      } else {
        client.add([5, 8, 0, 1, 0, 0, 0, 0, 0, 0]);
        return;
      }

      final portBytes = await reader.read(2);
      final port = (portBytes[0] << 8) | portBytes[1];

      final channel = await _client!.forwardLocal(host, port);

      client.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);

      // Await both pipes — keeps the connection alive until both sides close.
      await Future.wait([
        channel.stream.cast<List<int>>().pipe(client),
        reader.remainingStream().pipe(channel.sink),
      ]);
    } catch (_) {
      // ignore
    } finally {
      reader.cancel();
      client.destroy();
    }
  }

  String _formatIpv6(List<int> bytes) {
    final groups = <String>[];
    for (var i = 0; i < 16; i += 2) {
      groups.add(((bytes[i] << 8) | bytes[i + 1]).toRadixString(16));
    }
    return groups.join(':');
  }

  Future<void> stop() async {
    _running = false;
    await _socksServer?.close();
    _socksServer = null;
    _client?.close();
    _client = null;
  }
}

/// Single-subscription buffered reader over a Socket stream.
class _BufferedReader {
  final List<int> _buf = [];
  late final StreamSubscription<List<int>> _sub;
  Completer<void>? _pending;
  bool _done = false;

  _BufferedReader(Stream<List<int>> stream) {
    _sub = stream.listen(
      (chunk) {
        _buf.addAll(chunk);
        _pending?.complete();
        _pending = null;
      },
      onDone: () {
        _done = true;
        _pending?.complete();
        _pending = null;
      },
      onError: (e) {
        _done = true;
        _pending?.completeError(e);
        _pending = null;
      },
      cancelOnError: true,
    );
  }

  Future<List<int>> read(int count) async {
    while (_buf.length < count) {
      if (_done) throw StateError('Stream ended before $count bytes');
      _pending = Completer<void>();
      await _pending!.future;
    }
    final result = List<int>.unmodifiable(_buf.sublist(0, count));
    _buf.removeRange(0, count);
    return result;
  }

  /// Returns a stream: buffered bytes first, then live data from the socket.
  /// After calling this, do not call [read] again.
  Stream<List<int>> remainingStream() {
    final controller = StreamController<List<int>>();
    if (_buf.isNotEmpty) {
      controller.add(List<int>.of(_buf));
      _buf.clear();
    }
    _sub.onData((chunk) => controller.add(chunk));
    _sub.onDone(() => controller.close());
    _sub.onError((Object e, StackTrace s) => controller.addError(e, s));
    controller.onCancel = _sub.cancel;
    return controller.stream;
  }

  void cancel() => _sub.cancel();
}
