import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/models/server.dart';
import 'package:vzhukh/models/ssh_identity.dart';
import 'package:vzhukh/models/tunnel_route.dart';
import 'package:vzhukh/vpn/ssh_tunnel.dart';

// The tunnel runs against a real SSH server, built from
// go/tun2socks/cmd/sshtestserver. Freezing that process with SIGSTOP is what
// a laptop sees after sleeping: the socket still looks open and nothing on
// the other end answers.

late String _serverBinary;

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('vzhukh_sshtest');
    _serverBinary = '${dir.path}/sshtestserver';
    final build = await Process.run(
      'go',
      ['build', '-o', _serverBinary, './cmd/sshtestserver'],
      workingDirectory: 'go/tun2socks',
    );
    if (build.exitCode != 0) {
      throw StateError('go build failed: ${build.stderr}');
    }
  });

  late _TestServer server;
  late ServerSocket echo;
  late SshTunnel tunnel;
  late List<Object?> lost;

  setUp(() async {
    server = await _TestServer.start();
    echo = await _startEcho();
    lost = [];
    tunnel = SshTunnel(
      [server.hop],
      onChainLost: lost.add,
      port: 0,
    );
    await tunnel.start();
  });

  tearDown(() async {
    await tunnel.stop();
    await echo.close();
    server.kill();
  });

  test('carries a connection through the chain', () async {
    final conn = await _Socks.connect(tunnel.boundPort!, echo.port);
    expect(conn.replyCode, 0);
    expect(await conn.roundTrip('hello'), 'hello');
    conn.close();
  });

  test('a refused target is answered 5 and leaves the chain up', () async {
    final conn = await _Socks.connect(
      tunnel.boundPort!,
      80,
      host: 'refused.test',
    );
    expect(conn.replyCode, 5);
    conn.close();
    expect(tunnel.isChainUp, isTrue);
    expect(await tunnel.checkHealth(), isTrue);
    expect(lost, isEmpty);
  });

  test('a frozen server fails the probe and is reported once', () async {
    server.freeze();
    final watch = Stopwatch()..start();
    expect(await tunnel.checkHealth(), isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 7)));

    await _settle();
    expect(lost, hasLength(1));
    expect(tunnel.isChainUp, isFalse);
    expect(tunnel.isRunning, isTrue, reason: 'the listener outlives the chain');
  });

  test('reconnect brings the chain back under the same port', () async {
    final port = tunnel.boundPort;
    server.freeze();
    expect(await tunnel.checkHealth(), isFalse);
    server.thaw();

    await tunnel.reconnect();
    expect(tunnel.boundPort, port);

    final conn = await _Socks.connect(port!, echo.port);
    expect(conn.replyCode, 0);
    expect(await conn.roundTrip('after'), 'after');
    conn.close();
  });

  test('a request made while the chain is down waits for it', () async {
    server.freeze();
    expect(await tunnel.checkHealth(), isFalse);

    final pending = _Socks.connect(tunnel.boundPort!, echo.port);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    server.thaw();
    await tunnel.reconnect();

    final conn = await pending;
    expect(conn.replyCode, 0);
    expect(await conn.roundTrip('waited'), 'waited');
    conn.close();
  });

  test('a server that dies is reported without a probe', () async {
    server.kill();
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (lost.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(lost, hasLength(1));
    expect(tunnel.isChainUp, isFalse);
  });

  test('stop does not report the chain as lost', () async {
    await tunnel.stop();
    await _settle();
    expect(lost, isEmpty);
    expect(tunnel.isRunning, isFalse);
  });

  _authTests();
}

void _authTests() {
  group('with a login', () {
    late _TestServer server;
    late ServerSocket echo;
    late SshTunnel tunnel;
    const creds = SocksCredentials('u1', 'secret');

    setUp(() async {
      server = await _TestServer.start();
      echo = await _startEcho();
      tunnel = SshTunnel([server.hop], port: 0, credentials: creds);
      await tunnel.start();
    });

    tearDown(() async {
      await tunnel.stop();
      await echo.close();
      server.kill();
    });

    Future<List<int>> greet(List<int> methods) async {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, tunnel.boundPort!);
      s.add([5, methods.length, ...methods]);
      final reply = await s.first.timeout(const Duration(seconds: 5));
      s.destroy();
      return reply;
    }

    test('a client offering no login is turned away', () async {
      expect(await greet([0]), [5, 0xFF]);
    });

    Future<int> login(String user, String pass) async {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, tunnel.boundPort!);
      final it = StreamIterator(s);
      final buf = <int>[];
      Future<List<int>> read(int n) async {
        while (buf.length < n) {
          if (!await it.moveNext().timeout(const Duration(seconds: 5))) break;
          buf.addAll(it.current);
        }
        final out = buf.sublist(0, n);
        buf.removeRange(0, n);
        return out;
      }

      s.add([5, 1, 2]);
      expect(await read(2), [5, 2]);
      s.add([1, user.length, ...ascii.encode(user), pass.length, ...ascii.encode(pass)]);
      final status = (await read(2))[1];
      if (status == 0) {
        final port = echo.port;
        s.add([5, 1, 0, 1, 127, 0, 0, 1, port >> 8, port & 0xff]);
        final reply = await read(10);
        s.add(utf8.encode('hi'));
        expect(utf8.decode(await read(2)), 'hi');
        expect(reply[1], 0);
      }
      s.destroy();
      return status;
    }

    test('the wrong password is refused', () async {
      expect(await login('u1', 'nope'), isNot(0));
    });

    test('the right login carries traffic', () async {
      expect(await login('u1', 'secret'), 0);
    });

    test('random logins differ', () {
      final a = SocksCredentials.random(), b = SocksCredentials.random();
      expect(a.password, isNot(b.password));
      expect(a.password.length, 16);
    });
  });
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 100));

class _TestServer {
  final Process process;
  final int port;
  bool _frozen = false;

  _TestServer(this.process, this.port);

  static Future<_TestServer> start() async {
    final process = await Process.start(
      _serverBinary,
      ['-user', 'u', '-password', 'p'],
    );
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    final port = int.parse(line.split(' ').last);
    return _TestServer(process, port);
  }

  ResolvedHop get hop => ResolvedHop(
        server: Server(id: 's', host: '127.0.0.1', port: port, nickname: 's'),
        identity: const SshIdentity(
          id: 'i',
          serverId: 's',
          username: 'u',
          authType: SshAuthType.password,
          isAdmin: false,
          password: 'p',
        ),
      );

  void freeze() {
    _frozen = true;
    Process.killPid(process.pid, ProcessSignal.sigstop);
  }

  void thaw() {
    _frozen = false;
    Process.killPid(process.pid, ProcessSignal.sigcont);
  }

  void kill() {
    if (_frozen) thaw();
    process.kill(ProcessSignal.sigkill);
  }
}

Future<ServerSocket> _startEcho() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) => socket.listen(socket.add, onDone: socket.destroy));
  return server;
}

/// A SOCKS5 CONNECT through the tunnel to [host]:[target], 127.0.0.1 unless
/// a name is given.
class _Socks {
  final Socket socket;
  final StreamIterator<Uint8List> _in;
  final List<int> _buf = [];
  int replyCode = -1;

  _Socks(this.socket) : _in = StreamIterator(socket);

  static Future<_Socks> connect(
    int proxyPort,
    int target, {
    String? host,
  }) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort);
    final conn = _Socks(socket);
    socket.add([5, 1, 0]);
    expect(await conn._read(2), [5, 0]);
    final address = host == null
        ? [1, 127, 0, 0, 1]
        : [3, host.length, ...ascii.encode(host)];
    socket.add([5, 1, 0, ...address, target >> 8, target & 0xff]);
    final reply = await conn._read(10);
    conn.replyCode = reply[1];
    return conn;
  }

  Future<String> roundTrip(String message) async {
    socket.add(utf8.encode(message));
    return utf8.decode(await _read(message.length));
  }

  Future<List<int>> _read(int count) async {
    while (_buf.length < count) {
      if (!await _in.moveNext().timeout(const Duration(seconds: 15))) {
        throw StateError('closed after ${_buf.length} of $count bytes');
      }
      _buf.addAll(_in.current);
    }
    final out = _buf.sublist(0, count);
    _buf.removeRange(0, count);
    return out;
  }

  void close() => socket.destroy();
}
