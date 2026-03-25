#!/usr/bin/env dart
/// Build hook: downloads prebuilt libtun2socks.so from GitHub Releases
/// and places it in android/app/src/main/jniLibs/<abi>/.
///
/// Usage (called automatically by `flutter build apk`):
///   dart hook/build.dart
///
/// To build locally instead, run `scripts/build_native.sh`.

import 'dart:io';

// Update these when publishing a new release.
const _version = '0.1.0';
const _baseUrl =
    'https://github.com/nogipx/flume/releases/download/v$_version';

const _artifacts = {
  'arm64-v8a': 'libtun2socks_arm64.so',
  'x86_64': 'libtun2socks_x86_64.so',
};

// SHA-256 hashes — update whenever the binaries change.
const _hashes = <String, String>{
  'arm64-v8a': '', // fill in after first release build
  'x86_64': '',
};

Future<void> main() async {
  final root = _findProjectRoot();

  for (final entry in _artifacts.entries) {
    final abi = entry.key;
    final filename = entry.value;
    final destDir = Directory('$root/android/app/src/main/jniLibs/$abi');
    final destFile = File('${destDir.path}/libtun2socks.so');

    if (destFile.existsSync()) {
      stdout.writeln('[hook] $abi: already present, skipping download.');
      continue;
    }

    destDir.createSync(recursive: true);
    final url = '$_baseUrl/$filename';
    stdout.writeln('[hook] $abi: downloading $url …');

    final request = await HttpClient().getUrl(Uri.parse(url));
    final response = await request.close();

    if (response.statusCode != 200) {
      stderr.writeln('[hook] $abi: HTTP ${response.statusCode} for $url');
      stderr.writeln(
          '       Build the library locally with `scripts/build_native.sh`');
      exit(1);
    }

    final bytes = await response.fold<List<int>>(
      [],
      (buf, chunk) => buf..addAll(chunk),
    );

    destFile.writeAsBytesSync(bytes);
    stdout.writeln('[hook] $abi: saved to ${destFile.path}');
  }
}

String _findProjectRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not find pubspec.yaml');
    }
    dir = parent;
  }
  return dir.path;
}
