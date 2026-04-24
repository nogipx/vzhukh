import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import '../models/tunnel_route.dart';
import '../ssh/ssh_client_factory.dart';

/// Opens a chain of SSH connections and runs a SOCKS5 proxy on localhost:2080.
///
/// Single hop: equivalent to `ssh -D 2080 user@host`.
/// Multi-hop: each hop's SSH client forwards to the next server via
/// `forwardLocal`, which returns an `SSHForwardChannel` that already
/// implements `SSHSocket` — no adapters needed.
class SshTunnel {
  static const int socksPort = 2080;

  final List<ResolvedHop> hops;
  final void Function()? onDisconnected;

  final List<SSHClient> _clients = [];
  ServerSocket? _socksServer;
  bool _running = false;

  SshTunnel(this.hops, {this.onDisconnected})
      : assert(hops.isNotEmpty, 'At least one hop is required');

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;

    // Build SSH client chain.
    SSHSocket currentSocket = await SSHSocket.connect(
      hops.first.server.host,
      hops.first.server.port,
    );

    for (int i = 0; i < hops.length; i++) {
      final hop = hops[i];
      final client = buildSshClient(
        currentSocket,
        username: hop.identity.username,
        password: hop.identity.password,
        identities: hop.identity.privateKeyPem != null
            ? [...SSHKeyPair.fromPem(hop.identity.privateKeyPem!)]
            : null,
      );
      await client.authenticated;
      _clients.add(client);

      if (i < hops.length - 1) {
        final next = hops[i + 1];
        // SSHForwardChannel implements SSHSocket — pass directly to next client.
        currentSocket =
            await client.forwardLocal(next.server.host, next.server.port);
      }
    }

    // Open SOCKS5 proxy on the last client.
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
      final greeting = await reader.read(2);
      if (greeting[0] != 5) return;
      await reader.read(greeting[1]);
      client.add([5, 0]);

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

      final channel = await _clients.last.forwardLocal(host, port);
      client.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);

      await Future.wait([
        channel.stream.cast<List<int>>().pipe(client),
        reader.remainingStream().pipe(channel.sink),
      ]);
    } catch (_) {
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
    // Close clients in reverse order (last hop first).
    for (final client in _clients.reversed) {
      client.close();
    }
    _clients.clear();
  }
}

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
