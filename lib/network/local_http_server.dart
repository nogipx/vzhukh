import 'dart:io';

class ReceivedPayload {
  final String type; // 'route' | 'invite'
  final String data; // base64url encoded encrypted blob

  const ReceivedPayload({required this.type, required this.data});
}

/// Network utilities for local device-to-device transfer.
class LocalHttpServer {
  /// Returns the first non-loopback IPv4 address, or null if not connected.
  static Future<String?> localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // Prefer WiFi/ethernet interfaces over VPN tunnels.
      final preferred = ['wlan', 'eth', 'en'];
      for (final prefix in preferred) {
        for (final iface in interfaces) {
          if (iface.name.startsWith(prefix)) {
            final addr = iface.addresses.firstWhere(
              (a) => !a.isLoopback,
              orElse: () => iface.addresses.first,
            );
            if (!addr.isLoopback) return addr.address;
          }
        }
      }
      // Fallback: first non-loopback address.
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }
}
