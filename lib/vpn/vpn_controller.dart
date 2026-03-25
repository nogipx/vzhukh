import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/server_config.dart';
import 'ssh_tunnel.dart';
import 'tun2socks_bindings.dart';

enum VpnStatus { disconnected, connecting, connected, error }

class VpnController {
  static const _channel = MethodChannel('com.example.flume/vpn');

  final ValueNotifier<VpnStatus> status =
      ValueNotifier(VpnStatus.disconnected);
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  SshTunnel? _tunnel;
  int? _tunFd;
  bool _tun2socksRunning = false;

  Future<void> connect(ServerConfig config) async {
    if (status.value != VpnStatus.disconnected) return;

    status.value = VpnStatus.connecting;
    errorMessage.value = null;

    try {
      // Step 1: Start SSH tunnel + SOCKS5 proxy
      _tunnel = SshTunnel(config);
      await _tunnel!.start();

      // Step 2: Request VPN permission and create TUN interface
      _tunFd = await _channel.invokeMethod<int>('startVpn', {'sshHost': config.host});
      if (_tunFd == null || _tunFd! <= 0) {
        throw Exception('Failed to create TUN interface (fd=$_tunFd)');
      }

      // Step 3: Start tun2socks to route TUN → SOCKS5
      final result = Tun2SocksBindings.instance
          .start(_tunFd!, '127.0.0.1:${SshTunnel.socksPort}');
      if (result != 0) {
        throw Exception('tun2socks_start failed (code=$result)');
      }
      _tun2socksRunning = true;

      status.value = VpnStatus.connected;
    } catch (e) {
      errorMessage.value = e.toString();
      status.value = VpnStatus.error;
      await _cleanup();
    }
  }

  Future<void> disconnect() async {
    if (status.value == VpnStatus.disconnected) return;
    status.value = VpnStatus.disconnected;
    await _cleanup();
  }

  Future<void> _cleanup() async {
    if (_tun2socksRunning) {
      try {
        Tun2SocksBindings.instance.stop();
      } catch (_) {}
      _tun2socksRunning = false;
    }

    try {
      await _channel.invokeMethod('stopVpn');
    } catch (_) {}
    _tunFd = null;

    await _tunnel?.stop();
    _tunnel = null;
  }

  void dispose() {
    status.dispose();
    errorMessage.dispose();
  }
}
