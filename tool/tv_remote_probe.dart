// Полная проверка TvRemote: мышь, клавиатура, список приложений.
import 'dart:io';
import 'dart:math';
import 'package:vzhukh/remote/adb/adb_key.dart';
import 'package:vzhukh/remote/tv_remote.dart';
import 'package:vzhukh/remote/uhid.dart';

final f = File('/tmp/tv_remote_probe.log');
void say(String s) => f.writeAsStringSync('$s\n', mode: FileMode.append);

Future<void> main(List<String> args) async {
  f.writeAsStringSync('');
  Future<void>.delayed(const Duration(seconds: 70), () { say('!! timeout'); exit(2); });
  try {
    final key = AdbKey.fromJson(File('/tmp/vzhukh_adb_key.json').readAsStringSync());
    final tv = await TvRemote.connect(host: args.isNotEmpty ? args[0] : '192.168.0.168', key: key)
        .timeout(const Duration(seconds: 25));
    say('connected; mouse + keyboard created');

    final devs = await tv.shell('getevent -pl 2>/dev/null | grep -i vzhukh');
    say('devices:\n${devs.trim()}');

    final sw = Stopwatch()..start();
    for (var i = 0; i < 200; i++) {
      await tv.moveBy((7 * cos(i / 12)).round(), (7 * sin(i / 12)).round());
    }
    sw.stop();
    say('200 moves: ${sw.elapsedMilliseconds} ms (${(sw.elapsedMilliseconds/200).toStringAsFixed(2)} ms each)');

    say('D-pad down x2');
    await tv.tapKey(HidKey.down);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tv.tapKey(HidKey.down);

    final apps = await tv.listApps().timeout(const Duration(seconds: 15));
    say('apps: ${apps.length}');
    for (final a in apps.take(8)) { say('  - ${a.packageName}'); }

    await tv.close();
    say('done');
  } catch (e) {
    say('ERROR: $e');
  }
  exit(0);
}
