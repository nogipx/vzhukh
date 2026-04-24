import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/app_routing_config.dart';
import '../models/tunnel_route.dart';
import 'ssh_tunnel.dart';
import 'tun2socks_bindings.dart';

enum VpnStatus { disconnected, connecting, connected, reconnecting, error }

class VpnController {
  static const _channel = MethodChannel('dev.nogipx.vzhukh/vpn');
  static const _maxRetryDelay = Duration(seconds: 30);

  final ValueNotifier<VpnStatus> status =
      ValueNotifier(VpnStatus.disconnected);
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  SshTunnel? _tunnel;
  int? _tunFd;
  bool _tun2socksRunning = false;

  List<ResolvedHop>? _lastHops;
  AppRoutingConfig? _lastRouting;
  bool _userDisconnected = false;
  int _retryCount = 0;
  Timer? _retryTimer;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  List<ConnectivityResult>? _lastConnectivity;

  Future<void> connect(
    List<ResolvedHop> hops, {
    AppRoutingConfig? routing,
  }) async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _stopConnectivityMonitor();
    _userDisconnected = true; // prevent onDisconnected from scheduling reconnect during cleanup
    await _cleanupTunnel();

    _lastHops = hops;
    _lastRouting = routing;
    _userDisconnected = false;
    status.value = VpnStatus.connecting;
    errorMessage.value = null;

    try {
      _tunnel = SshTunnel(hops, onDisconnected: _onTunnelDisconnected);
      await _tunnel!.start();

      if (!Platform.isMacOS) {
        final firstServer = hops.first.server;
        _tunFd = await _channel.invokeMethod<int>('startVpn', {
          'sshHost': firstServer.host,
          'routingMode': routing?.mode.name ?? 'blacklist',
          'routingPackages': routing?.packages ?? [],
        });
        if (_tunFd == null || _tunFd! <= 0) {
          throw Exception('Failed to create TUN interface (fd=$_tunFd)');
        }

        final result = Tun2SocksBindings.instance
            .start(_tunFd!, '127.0.0.1:${SshTunnel.socksPort}');
        if (result != 0) {
          throw Exception('tun2socks_start failed (code=$result)');
        }
        _tun2socksRunning = true;
      }

      _retryCount = 0;
      status.value = VpnStatus.connected;
      _startConnectivityMonitor();
    } catch (e) {
      errorMessage.value = e.toString();
      await _cleanupTunnel();
      if (!_userDisconnected) {
        _scheduleReconnect();
      } else {
        status.value = VpnStatus.error;
      }
    }
  }

  Future<void> disconnect() async {
    if (status.value == VpnStatus.disconnected) return;
    _userDisconnected = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _stopConnectivityMonitor();
    status.value = VpnStatus.disconnected;
    await _cleanup();
  }

  void _onTunnelDisconnected() {
    if (_userDisconnected) return;
    _scheduleReconnect();
  }

  void _startConnectivityMonitor() {
    _connectivitySub?.cancel();
    _lastConnectivity = null;
    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen(_onConnectivityChanged);
  }

  void _stopConnectivityMonitor() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (_userDisconnected) return;

    final previous = _lastConnectivity;
    _lastConnectivity = results;

    if (previous == null) return;

    final hasNetwork = results.any((r) => r != ConnectivityResult.none);
    if (!hasNetwork) return;

    _retryCount = 0;
    _scheduleReconnect(delay: const Duration(seconds: 1));
  }

  void _scheduleReconnect({Duration? delay}) {
    if (_userDisconnected) return;
    _retryTimer?.cancel();

    final effectiveDelay = delay ?? _retryDelay();
    status.value = VpnStatus.reconnecting;
    errorMessage.value = null;

    _retryTimer = Timer(effectiveDelay, () async {
      if (_userDisconnected || _lastHops == null) return;
      _retryCount++;
      await _cleanupTunnel();
      await connect(_lastHops!, routing: _lastRouting);
    });
  }

  Duration _retryDelay() {
    final seconds = (1 << _retryCount.clamp(0, 5));
    return Duration(seconds: seconds).compareTo(_maxRetryDelay) < 0
        ? Duration(seconds: seconds)
        : _maxRetryDelay;
  }

  Future<void> _cleanup() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    await _cleanupTunnel();
  }

  Future<void> _cleanupTunnel() async {
    if (_tun2socksRunning) {
      try {
        Tun2SocksBindings.instance.stop();
      } catch (_) {}
      _tun2socksRunning = false;
    }

    if (!Platform.isMacOS) {
      try {
        await _channel.invokeMethod('stopVpn');
      } catch (_) {}
    }
    _tunFd = null;

    await _tunnel?.stop();
    _tunnel = null;
  }

  void dispose() {
    _retryTimer?.cancel();
    _stopConnectivityMonitor();
    status.dispose();
    errorMessage.dispose();
  }
}
