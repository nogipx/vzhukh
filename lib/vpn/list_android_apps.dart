import 'dart:io';

import 'package:flutter/services.dart';

import '../models/app_info.dart';

/// The apps installed on this Android device, with their icons. Empty
/// anywhere else, or when the platform cannot list them.
class ListAndroidApps {
  const ListAndroidApps();

  static const _channel = MethodChannel('dev.nogipx.vzhukh/vpn');

  Future<List<AppInfo>> call() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List>('getInstalledApps');
      return [
        for (final e in raw ?? const [])
          if (Map<String, dynamic>.from(e as Map) case final m)
            AppInfo(
              packageName: m['packageName'] as String,
              label: m['label'] as String,
              icon: m['icon'] != null ? Uint8List.fromList(List<int>.from(m['icon'] as List)) : null,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }
}
