import 'dart:io';

/// An app bundle on this Mac.
class InstalledApp {
  final String name;
  final String path;
  const InstalledApp(this.name, this.path);
}

/// Lists the .app bundles in the usual places, for picking rule targets.
class ListInstalledApps {
  const ListInstalledApps();

  Future<List<InstalledApp>> call() async {
    final home = Platform.environment['HOME'];
    final dirs = [
      '/Applications',
      '/Applications/Utilities',
      '/System/Applications',
      '/System/Applications/Utilities',
      if (home != null) '$home/Applications',
    ];
    final apps = <String, InstalledApp>{};
    for (final dir in dirs) {
      final d = Directory(dir);
      if (!await d.exists()) continue;
      await for (final entity in d.list(followLinks: false)) {
        final path = entity.path;
        if (!path.endsWith('.app')) continue;
        final name = path.split('/').last.replaceAll(RegExp(r'\.app$'), '');
        apps.putIfAbsent(path, () => InstalledApp(name, path));
      }
    }
    final list = apps.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }
}
