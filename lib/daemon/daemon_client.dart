import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'daemon_models.dart';

/// Thrown when the daemon answers a request with an error, as opposed to
/// not answering at all.
class DaemonError implements Exception {
  final String message;
  const DaemonError(this.message);
  @override
  String toString() => message;
}

/// Talks to vzhukhd over its Unix socket: one JSON object per line each
/// way, replies matched to requests by id (go/tun2socks/internal/daemon/ipc.go).
///
/// The connection is opened on first use and again after any failure, so a
/// daemon restarted by launchd is picked up without the app noticing.
class DaemonClient {
  static const defaultSocketPath = '/var/run/vzhukhd.sock';

  final String socketPath;

  DaemonClient({this.socketPath = defaultSocketPath});

  Socket? _socket;
  Future<Socket>? _connecting;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 0;

  Future<Socket> _connect() {
    final existing = _socket;
    if (existing != null) return Future.value(existing);
    return _connecting ??= () async {
      try {
        final socket = await Socket.connect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
          timeout: const Duration(seconds: 2),
        );
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(_onLine, onError: (_) => _drop(), onDone: _drop);
        _socket = socket;
        return socket;
      } finally {
        _connecting = null;
      }
    }();
  }

  void _onLine(String line) {
    final Map<String, dynamic> msg;
    try {
      msg = Map<String, dynamic>.from(jsonDecode(line) as Map);
    } catch (_) {
      return;
    }
    final completer = _pending.remove(msg['id']);
    if (completer == null) return;
    final error = msg['error'];
    if (error is String && error.isNotEmpty) {
      completer.completeError(DaemonError(error));
    } else {
      completer.complete(msg['result']);
    }
  }

  void _drop() {
    _socket?.destroy();
    _socket = null;
    final pending = Map.of(_pending);
    _pending.clear();
    for (final c in pending.values) {
      c.completeError(const SocketException('vzhukhd closed the connection'));
    }
  }

  Future<Object?> call(String method, [Object? params]) async {
    final socket = await _connect();
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    socket.write('${jsonEncode({
          'id': id,
          'method': method,
          if (params != null) 'params': params,
        })}\n');
    return completer.future.timeout(const Duration(seconds: 30), onTimeout: () {
      _pending.remove(id);
      _drop();
      throw TimeoutException('vzhukhd did not answer $method');
    });
  }

  /// The daemon's version, or null when nothing is listening.
  Future<String?> version() async {
    try {
      final result = await call('hello') as Map;
      return result['version'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<DaemonStatus> status() async => DaemonStatus.fromJson(
      Map<String, dynamic>.from(await call('status') as Map));

  Future<DaemonStatus> start(Map<String, dynamic> config) async =>
      DaemonStatus.fromJson(
          Map<String, dynamic>.from(await call('start', config) as Map));

  /// Replaces the rules of the running tunnel.
  Future<DaemonStatus> setRules(Map<String, dynamic> rules) async =>
      DaemonStatus.fromJson(
          Map<String, dynamic>.from(await call('rules', rules) as Map));

  Future<DaemonStatus> stop() async => DaemonStatus.fromJson(
      Map<String, dynamic>.from(await call('stop') as Map));

  Future<FlowSnapshot> flows({int since = 0}) async => FlowSnapshot.fromJson(
      Map<String, dynamic>.from(await call('flows', {'since': since}) as Map));

  /// Connections summed by app, host, port and decision over the last
  /// [window] minutes, or since the last clear for 0. A helper older than
  /// this method answers with an error.
  Future<FlowStats> stats({int window = 0}) async => FlowStats.fromJson(
      Map<String, dynamic>.from(await call('stats', {'window': window}) as Map));

  /// Starts or stops keeping closed connections and statistics. A helper
  /// older than this method answers with an error.
  Future<FlowSnapshot> setRecording(bool on) async => FlowSnapshot.fromJson(
      Map<String, dynamic>.from(await call('record', {'on': on}) as Map));

  /// Forgets closed connections and starts the totals again. A helper older
  /// than this method answers with an error.
  Future<FlowSnapshot> clearFlows() async => FlowSnapshot.fromJson(
      Map<String, dynamic>.from(await call('clearFlows') as Map));

  void close() => _drop();
}
