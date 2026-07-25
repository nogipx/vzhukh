// Exercises the ADB client against a real device without any Flutter UI.
//
//   fvm dart run tool/adb_probe.dart 192.168.0.168 5555
//
// The daemon only trusts a key it has been shown before, so the first run
// pops the "Allow debugging" dialog on the television.
import 'dart:io';

import 'package:vzhukh/remote/adb/adb_client.dart';
import 'package:vzhukh/remote/adb/adb_key.dart';

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '192.168.0.168';
  final port = args.length > 1 ? int.parse(args[1]) : 5555;

  final keyFile = File('/tmp/vzhukh_adb_key.json');
  final AdbKey key;
  if (keyFile.existsSync()) {
    key = AdbKey.fromJson(keyFile.readAsStringSync());
    stdout.writeln('key: reused');
  } else {
    stdout.writeln('key: generating RSA-2048 (a few seconds)...');
    key = AdbKey.generate();
    keyFile.writeAsStringSync(key.toJson());
    stdout.writeln('key: generated');
  }

  stdout.writeln('connecting to $host:$port ...');
  final client = await AdbClient.connect(
    host,
    port,
    key,
    onWaitingForAuth: () =>
        stdout.writeln('>> confirm the debugging prompt on the TV'),
  );
  stdout.writeln('connected');

  for (final command in ['echo hello-from-dart', 'getprop ro.product.model']) {
    final out = await client.run(command);
    stdout.writeln('\$ $command\n${out.trim()}');
  }

  await client.close();
  stdout.writeln('done');
}
