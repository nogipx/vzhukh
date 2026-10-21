import 'dart:typed_data';

class AppInfo {
  final String packageName;
  final String label;
  final Uint8List? icon;

  const AppInfo({
    required this.packageName,
    required this.label,
    this.icon,
  });
}
