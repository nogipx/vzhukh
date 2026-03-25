import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/server_config.dart';
import 'ssh_tunnel.dart';
import 'tun2socks_bindings.dart';

enum VpnStatus { disconnected, connecting, connected, reconnecting, error }

class VpnController {
  static const _channel = MethodChannel('com.example.flume/vpn');

  static const _maxRetryDelay = Duration(seconds: 30);

  final ValueNotifier<VpnStatus> status =
      ValueNotifier(VpnStatus.disconnected);
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  SshTunnel? _tunnel;
  int? _tunFd;
  bool _tun2socksRunning = false;

  ServerConfig? _lastConfig;
  bool _userDisconnected = false;
  int _retryCount = 0;
  Timer? _retryTimer;

  Future<void> connect(ServerConfig config) async {
    if (status.value != VpnStatus.disconnected &&
        status.value != VpnStatus.reconnecting) return;

    _lastConfig = config;
    _userDisconnected = false;
    status.value = VpnStatus.connecting;
    errorMessage.value = null;

    try {
      _tunnel = SshTunnel(config, onDisconnected: _onTunnelDisconnected);
      await _tunnel!.start();

      if (!Platform.isMacOS) {
        _tunFd = await _channel.invokeMethod<int>('startVpn', {'sshHost': config.host});
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
    _retryCount = 0;
    status.value = VpnStatus.disconnected;
    await _cleanup();
  }

  void _onTunnelDisconnected() {
    if (_userDisconnected) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_userDisconnected) return;
    _retryTimer?.cancel();

    final delay = _retryDelay();
    status.value = VpnStatus.reconnecting;
    errorMessage.value = null;

    _retryTimer = Timer(delay, () async {
      if (_userDisconnected || _lastConfig == null) return;
      _retryCount++;
      await _cleanupTunnel();
      await connect(_lastConfig!);
    });
  }

  Duration _retryDelay() {
    final seconds = (1 << _retryCount.clamp(0, 5)); // 1, 2, 4, 8, 16, 32 → capped
    return Duration(seconds: seconds).compareTo(_maxRetryDelay) < 0
        ? Duration(seconds: seconds)
        : _maxRetryDelay;
  }

  Future<void> _cleanup() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    await _cleanupTunnel();
  }

  /// Tears down the tunnel without resetting user-disconnect state or retries.
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
    status.dispose();
    errorMessage.dispose();
  }
}
