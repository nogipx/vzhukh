import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../vpn/vpn_controller.dart';

/// "2.1.0 (3)": the version and the build number, as a bug report wants them.
Future<String> appVersion() async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
}

/// The app's version and, on a Mac, the helper's: an older helper than the
/// app expects behaves differently, and this is where to see it.
Future<void> showAbout(BuildContext context, VpnController vpn) async {
  final version = await appVersion();
  final mac = vpn.macDaemon;
  final helper = mac == null ? null : await mac.client.version();
  if (!context.mounted) return;
  showAboutDialog(
    context: context,
    applicationName: 'Vzhukh',
    applicationVersion: version,
    applicationLegalese: 'Routes traffic through your own SSH servers.',
    children: [
      if (mac != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(helper == null ? 'Helper: not running' : 'Helper: v$helper'),
        ),
    ],
  );
}
