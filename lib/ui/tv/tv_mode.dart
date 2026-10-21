import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Asks the platform whether this device is a TV.
///
/// Resolved once during startup rather than per build: the answer cannot
/// change while the app is running, and knowing it before the first frame
/// avoids briefly laying out the handheld shell on a television.
class DetectTvMode {
  const DetectTvMode();

  static const _channel = MethodChannel('dev.nogipx.vzhukh/vpn');

  Future<bool> call() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isTv') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// Exposes the resolved form factor to the widget tree.
class TvMode extends InheritedWidget {
  const TvMode({super.key, required this.isTv, required super.child});

  final bool isTv;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvMode>()?.isTv ?? false;

  @override
  bool updateShouldNotify(TvMode oldWidget) => isTv != oldWidget.isTv;
}
