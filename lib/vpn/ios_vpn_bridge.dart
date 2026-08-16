import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/tunnel_route.dart';

/// What the system reports about the tunnel, which is not quite what the app
/// tracks: `reasserting` has no counterpart on Android, and `invalid` means
/// the configuration has been removed from Settings rather than that anything
/// went wrong.
enum IosTunnelStatus {
  invalid,
  disconnected,
  connecting,
  connected,
  reasserting,
  disconnecting,
}

/// Talks to the tunnel on iOS.
///
/// On Android the Dart side owns the SSH connection and asks the platform only
/// for a TUN descriptor. Here it owns nothing at all: the tunnel runs in a
/// NetworkExtension that keeps going after the app is suspended, so this is a
/// remote control rather than an implementation.
///
/// One consequence worth stating: retries are not this class's business. The
/// extension reconnects itself, because when a phone drops its connection at
/// three in the morning there is no app running to notice.
class IosVpnBridge {
  static const _methods = MethodChannel('dev.nogipx.vzhukh/vpn');
  static const _events = EventChannel('dev.nogipx.vzhukh/vpn_status');

  /// Defaults matching VzhukhVpnService on Android, so both platforms hand the
  /// packet engine the same numbers.
  static const _address = '10.0.0.2/30';
  static const _mtu = 1500;
  static const _dnsServers = ['8.8.8.8', '8.8.4.4'];

  Stream<IosTunnelStatus>? _status;

  /// Emits whenever the system's view of the tunnel changes, starting with
  /// wherever it stands at the moment of subscribing.
  Stream<IosTunnelStatus> get status {
    return _status ??= _events
        .receiveBroadcastStream()
        .map((event) => _parseStatus(event as String?))
        .asBroadcastStream();
  }

  /// Installs the configuration and asks the system to bring the tunnel up.
  ///
  /// Returning does not mean it is up — it means the request was accepted.
  /// Watch [status] for the rest.
  Future<void> start(List<ResolvedHop> hops) async {
    if (hops.isEmpty) {
      throw ArgumentError('At least one hop is required');
    }

    final config = <String, dynamic>{
      'hops': hops.map(_hopToJson).toList(),
      'address': _address,
      'mtu': _mtu,
      'dnsServers': _dnsServers,
    };

    await _methods.invokeMethod<void>('startVpn', {'config': jsonEncode(config)});
  }

  Future<void> stop() => _methods.invokeMethod<void>('stopVpn');

  /// Asks the system directly, for the case where nothing is listening to
  /// [status] yet.
  Future<IosTunnelStatus> currentStatus() async {
    final name = await _methods.invokeMethod<String>('vpnStatus');
    return _parseStatus(name);
  }

  /// The shape the Go engine parses; see internal/sshtun/sshtun.go.
  ///
  /// Absent credentials are left out rather than sent as null, because the
  /// Swift model treats a missing key and an explicit null the same way and
  /// omitting them keeps the stored JSON smaller.
  static Map<String, dynamic> _hopToJson(ResolvedHop hop) {
    final password = hop.identity.password;
    final privateKey = hop.identity.privateKeyPem;

    return {
      'host': hop.server.host,
      'port': hop.server.port,
      'username': hop.identity.username,
      if (password != null && password.isNotEmpty) 'password': password,
      if (privateKey != null && privateKey.isNotEmpty) 'privateKeyPem': privateKey,
    };
  }

  static IosTunnelStatus _parseStatus(String? name) {
    switch (name) {
      case 'disconnected':
        return IosTunnelStatus.disconnected;
      case 'connecting':
        return IosTunnelStatus.connecting;
      case 'connected':
        return IosTunnelStatus.connected;
      case 'reasserting':
        return IosTunnelStatus.reasserting;
      case 'disconnecting':
        return IosTunnelStatus.disconnecting;
      default:
        return IosTunnelStatus.invalid;
    }
  }
}
