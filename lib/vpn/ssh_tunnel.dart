import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dartssh2/dartssh2.dart';
import '../models/tunnel_route.dart';
import '../ssh/ssh_client_factory.dart';

/// Opens a chain of SSH connections and runs a SOCKS5 proxy on localhost:2080.
///
/// Single hop: equivalent to `ssh -D 2080 user@host`.
/// Multi-hop: each hop's SSH client forwards to the next server via
/// `forwardLocal`, which returns an `SSHForwardChannel` that already
/// implements `SSHSocket` — no adapters needed.
///
/// The listener and the chain have separate lifetimes. The listener is bound
/// once in [start] and stays until [stop]; the chain under it can die and be
/// rebuilt with [reconnect] any number of times. Whatever is pointed at the
/// port — tun2socks on Android, Proxifier or a browser on macOS — never sees
/// the port vanish, only connections that wait while the chain comes back.
class SshTunnel {
  static const int socksPort = 2080;

  static const _connectTimeout = Duration(seconds: 10);
  static const _authTimeout = Duration(seconds: 15);
  static const _forwardTimeout = Duration(seconds: 15);
  static const _probeTimeout = Duration(seconds: 5);

  /// How long a SOCKS connection that arrives while the chain is down waits
  /// for it before being refused.
  static const _chainWait = Duration(seconds: 10);

  final List<ResolvedHop> hops;

  /// Port to listen on. 0 picks a free one, which only tests want; read it
  /// back from [boundPort].
  final int port;

  /// Called once per chain that dies without [stop] or [reconnect] asking for
  /// it: a hop's transport closed, or a probe went unanswered. The listener is
  /// still bound when this fires.
  final void Function(Object? reason)? onChainLost;

  ServerSocket? _socksServer;
  final Set<Socket> _socksClients = {};
  _SshChain? _chain;
  Completer<void> _chainUp = Completer<void>();
  Future<bool>? _probe;
  bool _stopped = false;

  /// Login the SOCKS listener demands, or none.
  final SocksCredentials? credentials;

  SshTunnel(this.hops, {this.onChainLost, this.port = socksPort, this.credentials})
      : assert(hops.isNotEmpty, 'At least one hop is required');

  bool get isRunning => _socksServer != null && !_stopped;

  bool get isChainUp => _chain != null;

  int? get boundPort => _socksServer?.port;

  /// Dials the chain, then binds the listener. A chain that cannot be built
  /// fails here and leaves nothing bound.
  Future<void> start() async {
    if (_socksServer != null) return;
    _stopped = false;

    _setChain(await _SshChain.dial(hops));
    try {
      _socksServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
    } catch (_) {
      _dropChain();
      rethrow;
    }
    _socksServer!.listen(_handleSocksClient, onError: (_) {});
  }

  /// Throws the current chain away, if there is one, and dials a new one.
  /// The listener keeps accepting throughout.
  Future<void> reconnect() async {
    if (_stopped) throw StateError('Tunnel is stopped');
    _dropChain();

    final chain = await _SshChain.dial(hops);
    if (_stopped) {
      chain.close();
      throw StateError('Tunnel stopped while reconnecting');
    }
    _setChain(chain);
  }

  /// Pings the far end of the chain and drops the chain when the reply does
  /// not come in time, which reports it through [onChainLost].
  ///
  /// The ping travels every hop, so one probe covers the whole path. After a
  /// sleep the TCP socket usually still looks open while the server or a NAT
  /// on the way forgot it long ago; nothing but an unanswered request shows
  /// that. Concurrent calls share one probe. Returns whether the chain is up.
  Future<bool> checkHealth() {
    final chain = _chain;
    if (chain == null) return Future.value(false);
    return _probe ??= _runProbe(chain).whenComplete(() => _probe = null);
  }

  Future<bool> _runProbe(_SshChain chain) async {
    try {
      await chain.ping().timeout(_probeTimeout);
      return true;
    } on TimeoutException {
      chain.markLost(
        'No keepalive reply within ${_probeTimeout.inSeconds}s',
      );
      return false;
    } catch (e) {
      chain.markLost(e);
      return false;
    }
  }

  void _setChain(_SshChain chain) {
    _chain = chain;
    if (!_chainUp.isCompleted) _chainUp.complete();
    chain.lost.then((reason) {
      if (!identical(_chain, chain)) return;
      _forgetChain();
      onChainLost?.call(reason);
    });
  }

  void _dropChain() {
    final chain = _chain;
    _forgetChain();
    chain?.close();
  }

  void _forgetChain() {
    _chain = null;
    if (_chainUp.isCompleted) _chainUp = Completer<void>();
  }

  Future<_SshChain?> _awaitChain() async {
    final deadline = DateTime.now().add(_chainWait);
    while (!_stopped) {
      final chain = _chain;
      if (chain != null) return chain;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      try {
        await _chainUp.future.timeout(left);
      } on TimeoutException {
        return null;
      }
    }
    return null;
  }

  Future<void> _handleSocksClient(Socket client) async {
    _socksClients.add(client);
    final reader = _BufferedReader(client);
    try {
      final greeting = await reader.read(2);
      if (greeting[0] != 5) return;
      final methods = await reader.read(greeting[1]);
      final auth = credentials;
      if (auth == null) {
        client.add([5, 0]);
      } else {
        // Username and password (RFC 1929) or nothing: an app that found
        // the port gets no further than this.
        if (!methods.contains(2)) {
          client.add([5, 0xFF]);
          return;
        }
        client.add([5, 2]);
        final ver = await reader.read(2);
        final user = String.fromCharCodes(await reader.read(ver[1]));
        final passLen = (await reader.read(1))[0];
        final pass = String.fromCharCodes(await reader.read(passLen));
        final ok = ver[0] == 1 && user == auth.user && pass == auth.password;
        client.add([1, ok ? 0 : 1]);
        if (!ok) return;
      }

      final req = await reader.read(4);
      if (req[0] != 5 || req[1] != 1) {
        client.add(_reply(7));
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
        client.add(_reply(8));
        return;
      }

      final portBytes = await reader.read(2);
      final port = (portBytes[0] << 8) | portBytes[1];

      final chain = await _awaitChain();
      if (chain == null) {
        client.add(_reply(1));
        return;
      }

      final SSHForwardChannel channel;
      try {
        channel = await _forward(chain, host, port);
      } on SSHChannelOpenError {
        // The server answered and refused: the chain is fine, the target
        // is not.
        client.add(_reply(5));
        return;
      } catch (_) {
        // No answer at all. That is what a chain that died silently looks
        // like, so find out now rather than at the next scheduled probe.
        unawaited(checkHealth());
        client.add(_reply(1));
        return;
      }
      client.add(_reply(0));

      await Future.wait([
        channel.stream.cast<List<int>>().pipe(client),
        reader.remainingStream().pipe(channel.sink),
      ]);
    } catch (_) {
    } finally {
      _socksClients.remove(client);
      reader.cancel();
      client.destroy();
    }
  }

  Future<SSHForwardChannel> _forward(_SshChain chain, String host, int port) {
    final pending = chain.forward(host, port);
    return pending.timeout(_forwardTimeout, onTimeout: () {
      // A channel that opens after we gave up would otherwise stay open on
      // the server with nobody reading it.
      pending.then((late) => late.close(), onError: (_) {});
      throw TimeoutException('Opening $host:$port', _forwardTimeout);
    });
  }

  /// A SOCKS5 reply with [code] and an all-zero IPv4 bind address.
  List<int> _reply(int code) => [5, code, 0, 1, 0, 0, 0, 0, 0, 0];

  String _formatIpv6(List<int> bytes) {
    final groups = <String>[];
    for (var i = 0; i < 16; i += 2) {
      groups.add(((bytes[i] << 8) | bytes[i + 1]).toRadixString(16));
    }
    return groups.join(':');
  }

  Future<void> stop() async {
    _stopped = true;
    final server = _socksServer;
    _socksServer = null;
    await server?.close();
    for (final client in _socksClients.toList()) {
      client.destroy();
    }
    _socksClients.clear();
    _dropChain();
  }
}

/// One built chain of SSH clients, last hop last. Never rebuilt: when it dies
/// the tunnel dials a new one.
class _SshChain {
  final List<SSHClient> _clients;
  final Completer<Object?> _lost = Completer<Object?>();
  bool _closed = false;

  _SshChain._(this._clients) {
    for (final client in _clients) {
      client.done.then(
        (_) => markLost('SSH connection closed'),
        onError: (Object e) => markLost(e),
      );
    }
  }

  /// Completes with the reason when the chain dies on its own. Never
  /// completes for a chain that was [close]d.
  Future<Object?> get lost => _lost.future;

  static Future<_SshChain> dial(List<ResolvedHop> hops) async {
    final clients = <SSHClient>[];
    try {
      SSHSocket socket = await SSHSocket.connect(
        hops.first.server.host,
        hops.first.server.port,
        timeout: SshTunnel._connectTimeout,
      );

      for (int i = 0; i < hops.length; i++) {
        final hop = hops[i];
        final client = buildSshClient(
          socket,
          username: hop.identity.username,
          password: hop.identity.password,
          identities: hop.identity.privateKeyPem != null
              ? [...SSHKeyPair.fromPem(hop.identity.privateKeyPem!)]
              : null,
          keepAliveInterval: null,
        );
        clients.add(client);
        await client.authenticated.timeout(SshTunnel._authTimeout);

        if (i < hops.length - 1) {
          final next = hops[i + 1];
          // SSHForwardChannel implements SSHSocket — pass directly to next
          // client.
          socket = await client
              .forwardLocal(next.server.host, next.server.port)
              .timeout(SshTunnel._forwardTimeout);
        }
      }
    } catch (_) {
      for (final client in clients.reversed) {
        client.close();
      }
      rethrow;
    }
    return _SshChain._(clients);
  }

  Future<void> ping() => _clients.last.ping();

  Future<SSHForwardChannel> forward(String host, int port) =>
      _clients.last.forwardLocal(host, port);

  void markLost(Object? reason) {
    if (_closed) return;
    close();
    _lost.complete(reason);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    // Last hop first: each one runs inside a channel of the one before it.
    for (final client in _clients.reversed) {
      client.close();
    }
  }
}

/// A SOCKS5 login (RFC 1929).
class SocksCredentials {
  final String user;
  final String password;
  const SocksCredentials(this.user, this.password);

  /// Random, for one connection.
  factory SocksCredentials.random() {
    final rnd = Random.secure();
    String token() => List.generate(16, (_) => rnd.nextInt(36).toRadixString(36)).join();
    return SocksCredentials(token(), token());
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
