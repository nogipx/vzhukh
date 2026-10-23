import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/app_routing_config.dart';
import '../models/tunnel_route.dart';
import 'ios_vpn_bridge.dart';

/// The route as the Android tunnel reports it.
enum AndroidTunnelState { stopped, connecting, up, down }

class AndroidTunnelStatus {
  final AndroidTunnelState state;
  final String? error;
  const AndroidTunnelStatus(this.state, this.error);
}

/// Hands a chain to the VpnService, which runs the tunnel in Go
/// (go/tun2socks/main.go, internal/mobile) and keeps it up on its own:
/// reconnects, sleep, network changes. The app only starts, stops and
/// watches, so closing it leaves the tunnel running.
class AndroidVpnBridge {
  static const _channel = MethodChannel('dev.nogipx.vzhukh/vpn');

  Future<void> start(List<ResolvedHop> hops, {AppRoutingConfig? routing, String? name}) async {
    final config = jsonEncode({
      if (name != null) 'name': name,
      'hops': hops.map(IosVpnBridge.hopToJson).toList(),
      'address': '10.0.0.2/32',
      'mtu': 1500,
    });
    await _channel.invokeMethod<bool>('startVpn', {
      'config': config,
      'routingMode': routing?.mode.name ?? 'blacklist',
      'routingPackages': routing?.packages ?? const <String>[],
      'dnsServers': IosVpnBridge.dnsServersFor(hops),
    });
  }

  Future<void> stop() => _channel.invokeMethod('stopVpn');

  Future<AndroidTunnelStatus> status() async {
    final raw = await _channel.invokeMethod<String>('vpnStatus');
    final json = raw == null ? const {} : jsonDecode(raw) as Map;
    final state = switch (json['state']) {
      'up' => AndroidTunnelState.up,
      'connecting' => AndroidTunnelState.connecting,
      'down' => AndroidTunnelState.down,
      _ => AndroidTunnelState.stopped,
    };
    return AndroidTunnelStatus(state, json['error'] as String?);
  }
}
