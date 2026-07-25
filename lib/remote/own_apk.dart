import 'dart:io';

import 'package:flutter/services.dart';

/// Reads this app's own installed package.
///
/// Installing Vzhukh on a television means having the APK to hand. Downloading
/// one would mean hosting it somewhere and trusting that link; the copy
/// already on the phone is the same build, needs no network, and is readable
/// by the app that owns it.
class ReadOwnApk {
  const ReadOwnApk();

  static const _channel = MethodChannel('dev.nogipx.vzhukh/vpn');

  Future<Uint8List> call() async {
    final path = await _channel.invokeMethod<String>('getOwnApkPath');
    if (path == null) {
      throw StateError('Could not locate the installed package');
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('Package file is missing at $path');
    }
    return file.readAsBytes();
  }
}
