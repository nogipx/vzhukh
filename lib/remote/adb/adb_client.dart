import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'adb_key.dart';
import 'adb_message.dart';

/// A stream multiplexed over an ADB connection — one shell, one file transfer.
class AdbStream {
  AdbStream._(this._client, this.localId);

  final AdbClient _client;
  final int localId;

  int _remoteId = 0;
  final _output = StreamController<Uint8List>();
  Completer<void>? _writeAck;
  bool _closed = false;

  Stream<Uint8List> get output => _output.stream;
  bool get isClosed => _closed;

  /// Reads everything the stream produces until the far end closes it.
  Future<String> readAll() async {
    final buffer = StringBuffer();
    await for (final chunk in output) {
      buffer.write(utf8.decode(chunk, allowMalformed: true));
    }
    return buffer.toString();
  }

  /// The daemon acknowledges every write, so each one waits for its OKAY
  /// before the next goes out.
  Future<void> write(List<int> data) async {
    if (_closed) throw StateError('Stream closed');
    var offset = 0;
    while (offset < data.length) {
      final end = (offset + _client.maxData).clamp(0, data.length);
      final chunk = Uint8List.fromList(data.sublist(offset, end));
      _writeAck = Completer<void>();
      _client._send(AdbMessage(AdbMessage.wrte, localId, _remoteId, chunk));
      await _writeAck!.future;
      offset = end;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client._send(
      AdbMessage(AdbMessage.clse, localId, _remoteId, Uint8List(0)),
    );
    await _output.close();
  }

  void _handleClose() {
    if (_closed) return;
    _closed = true;
    _writeAck?.complete();
    _output.close();
  }
}

/// Speaks the ADB protocol directly, so no adb binary is needed on the phone.
class AdbClient {
  AdbClient._(this._socket, this.maxData);

  final Socket _socket;
  final int maxData;

  final _reader = AdbMessageReader();
  final _streams = <int, AdbStream>{};
  final _pendingOpens = <int, Completer<AdbStream>>{};

  int _nextLocalId = 1;

  /// Connects and authenticates.
  ///
  /// [onWaitingForAuth] fires when the daemon has been handed our public key
  /// and is showing its confirmation dialog — the caller can tell the user to
  /// look at the screen instead of appearing to hang.
  static Future<AdbClient> connect(
    String host,
    int port,
    AdbKey key, {
    void Function()? onWaitingForAuth,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);

    final client = AdbClient._(socket, 256 * 1024);
    final ready = Completer<AdbClient>();
    var sentPublicKey = false;

    socket.listen(
      (chunk) {
        client._reader.add(chunk);
        for (var m = client._reader.next(); m != null; m = client._reader.next()) {
          switch (m.command) {
            case AdbMessage.cnxn:
              if (!ready.isCompleted) ready.complete(client);

            case AdbMessage.auth:
              if (m.arg0 != AdbMessage.authToken) break;
              if (!sentPublicKey) {
                // First challenge: prove we already hold a trusted key.
                client._send(AdbMessage(
                  AdbMessage.auth,
                  AdbMessage.authSignature,
                  0,
                  key.sign(m.payload),
                ));
                sentPublicKey = true;
              } else {
                // It did not know us, so offer the key and wait for the user.
                onWaitingForAuth?.call();
                client._send(AdbMessage(
                  AdbMessage.auth,
                  AdbMessage.authRsaPublicKey,
                  0,
                  Uint8List.fromList(
                    utf8.encode('${key.publicKeyBlob()}\x00'),
                  ),
                ));
              }

            default:
              client._dispatch(m);
          }
        }
      },
      onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(const SocketException('Connection closed'));
        }
        client._closeAllStreams();
      },
      cancelOnError: true,
    );

    client._send(AdbMessage(
      AdbMessage.cnxn,
      0x01000000,
      256 * 1024,
      Uint8List.fromList(utf8.encode('host::features=shell_v2,cmd\x00')),
    ));

    return ready.future;
  }

  /// Opens a service such as `shell:ls`, `exec:cat >file` or `sync:`.
  Future<AdbStream> open(String service) async {
    final localId = _nextLocalId++;
    final stream = AdbStream._(this, localId);
    _streams[localId] = stream;

    final opened = Completer<AdbStream>();
    _pendingOpens[localId] = opened;

    _send(AdbMessage(
      AdbMessage.open,
      localId,
      0,
      Uint8List.fromList(utf8.encode('$service\x00')),
    ));
    return opened.future;
  }

  /// Runs a command and returns everything it printed.
  ///
  /// `exec:` rather than `shell:` — no pseudo terminal means the bytes arrive
  /// exactly as written, which matters when the payload is binary.
  Future<String> run(String command) async {
    final stream = await open('exec:$command');
    return stream.readAll();
  }

  void _dispatch(AdbMessage m) {
    switch (m.command) {
      case AdbMessage.okay:
        final stream = _streams[m.arg1];
        if (stream == null) return;
        stream._remoteId = m.arg0;
        final pending = _pendingOpens.remove(m.arg1);
        if (pending != null) {
          pending.complete(stream);
        } else {
          stream._writeAck?.complete();
          stream._writeAck = null;
        }

      case AdbMessage.wrte:
        final stream = _streams[m.arg1];
        if (stream == null) return;
        if (!stream._output.isClosed) stream._output.add(m.payload);
        _send(AdbMessage(AdbMessage.okay, m.arg1, m.arg0, Uint8List(0)));

      case AdbMessage.clse:
        final pending = _pendingOpens.remove(m.arg1);
        pending?.completeError(StateError('Service refused'));
        _streams.remove(m.arg1)?._handleClose();
    }
  }

  void _send(AdbMessage message) => _socket.add(message.encode());

  void _closeAllStreams() {
    for (final stream in _streams.values.toList()) {
      stream._handleClose();
    }
    _streams.clear();
    for (final pending in _pendingOpens.values) {
      if (!pending.isCompleted) {
        pending.completeError(const SocketException('Connection closed'));
      }
    }
    _pendingOpens.clear();
  }

  Future<void> close() async {
    _closeAllStreams();
    await _socket.close();
  }
}
