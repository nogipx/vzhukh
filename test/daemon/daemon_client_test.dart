import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/daemon/daemon_client.dart';

/// A stand-in for vzhukhd on a unix socket: answers hello with [pid], and
/// restart the way the real one does, by answering and then going away.
Future<ServerSocket> _fakeDaemon(String path, int pid, {bool knowsRestart = true}) async {
  final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
  var gone = false;
  server.listen((conn) {
    conn.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
      if (gone) return;
      final req = jsonDecode(line) as Map;
      final reply = switch (req['method']) {
        'hello' => {'id': req['id'], 'result': {'version': '38', 'pid': pid}},
        'restart' when knowsRestart => {'id': req['id'], 'result': {'restarting': true, 'pid': pid}},
        final m => {'id': req['id'], 'error': 'unknown method "$m"'},
      };
      conn.write('${jsonEncode(reply)}\n');
      if (req['method'] == 'restart' && knowsRestart) {
        gone = true;
        await conn.flush();
        await conn.close();
        await server.close();
      }
    });
  });
  return server;
}

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vzhukhd');
    path = '${dir.path}/d.sock';
  });
  tearDown(() => dir.delete(recursive: true));

  test('a restarted daemon answers again as a new process', () async {
    await _fakeDaemon(path, 100);
    final client = DaemonClient(socketPath: path);
    expect((await client.hello())?.pid, 100);

    await client.restart();
    expect(await client.hello(), isNull, reason: 'nothing listens while it restarts');

    final next = await _fakeDaemon(path, 101);
    expect((await client.hello())?.pid, 101);
    client.close();
    await next.close();
  });

  test('an older daemon refuses restart with a DaemonError', () async {
    final server = await _fakeDaemon(path, 100, knowsRestart: false);
    final client = DaemonClient(socketPath: path);
    await expectLater(client.restart(), throwsA(isA<DaemonError>()));
    client.close();
    await server.close();
  });
}
