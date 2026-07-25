import 'dart:async';
import 'dart:io';

import '../network/local_http_server.dart';

class DiscoveredDevice {
  const DiscoveredDevice({required this.host, required this.port});

  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredDevice && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// Finds televisions on the local network by looking for an open ADB port.
///
/// A plain sweep rather than mDNS: the service names Android advertises for
/// debugging differ between versions and are often absent on the cheaper
/// boxes, while a listening port is the thing that actually has to be true for
/// any of this to work.
class DiscoverDevices {
  const DiscoverDevices({
    this.port = 5555,
    this.timeout = const Duration(milliseconds: 600),
    this.concurrency = 64,
  });

  final int port;
  final Duration timeout;
  final int concurrency;

  /// Emits devices as they answer, so the list fills in rather than appearing
  /// all at once at the end.
  Stream<DiscoveredDevice> call() async* {
    final local = await LocalHttpServer.localIp();
    if (local == null) return;

    final parts = local.split('.');
    if (parts.length != 4) return;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
    final self = int.tryParse(parts[3]);

    final candidates = [
      for (var i = 1; i < 255; i++)
        if (i != self) '$prefix.$i',
    ];

    for (var i = 0; i < candidates.length; i += concurrency) {
      final batch = candidates.skip(i).take(concurrency);
      final results = await Future.wait(batch.map(_probe));
      for (final host in results) {
        if (host != null) yield DiscoveredDevice(host: host, port: port);
      }
    }
  }

  Future<String?> _probe(String host) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return host;
    } catch (_) {
      return null;
    }
  }
}
