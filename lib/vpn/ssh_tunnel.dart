import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import '../models/server_config.dart';

/// Opens an SSH connection and runs a SOCKS5 proxy on localhost:2080.
/// This is the Dart equivalent of `ssh -D 2080 user@host`.
class SshTunnel {
  static const int socksPort = 2080;

  final ServerConfig config;

  SSHClient? _client;
  ServerSocket? _socksServer;
  bool _running = false;

  SshTunnel(this.config);

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
      onDone: () => _running = false,
    );
  }

  Future<void> _handleSocksClient(Socket client) async {
    try {
      // Read SOCKS5 greeting: version + auth methods
      final greeting = await _readBytes(client, 2);
      if (greeting[0] != 5) {
        client.destroy();
        return;
      }
      final nmethods = greeting[1];
      await _readBytes(client, nmethods); // consume methods
      // Reply: no auth required
      client.add([5, 0]);

      // Read request
      final req = await _readBytes(client, 4);
      if (req[0] != 5 || req[1] != 1) {
        // Only CONNECT supported
        client.add([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
        client.destroy();
        return;
      }

      String host;
      final atyp = req[3];
      if (atyp == 1) {
        // IPv4
        final addr = await _readBytes(client, 4);
        host = addr.join('.');
      } else if (atyp == 3) {
        // Domain
        final lenByte = await _readBytes(client, 1);
        final domain = await _readBytes(client, lenByte[0]);
        host = String.fromCharCodes(domain);
      } else if (atyp == 4) {
        // IPv6
        final addr = await _readBytes(client, 16);
        host = '[${_formatIpv6(addr)}]';
      } else {
        client.add([5, 8, 0, 1, 0, 0, 0, 0, 0, 0]);
        client.destroy();
        return;
      }

      final portBytes = await _readBytes(client, 2);
      final port = (portBytes[0] << 8) | portBytes[1];

      // Open SSH channel to target
      final channel = await _client!.forwardLocal(host, port);

      // Reply success
      client.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);

      // Pipe bidirectionally
      channel.stream.cast<List<int>>().pipe(client);
      client.cast<List<int>>().pipe(channel.sink);
    } catch (_) {
      client.destroy();
    }
  }

  Future<List<int>> _readBytes(Socket socket, int count) async {
    final buf = <int>[];
    await for (final chunk in socket) {
      buf.addAll(chunk);
      if (buf.length >= count) break;
    }
    return buf.sublist(0, count);
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
