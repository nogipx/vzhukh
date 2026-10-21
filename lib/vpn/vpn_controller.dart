import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/app_routing_config.dart';
import '../models/tunnel_route.dart';
import 'connection_ref.dart';
import 'ios_vpn_bridge.dart';
import 'android_vpn_bridge.dart';
import 'macos_daemon_backend.dart';
import 'ssh_tunnel.dart';

enum VpnStatus { disconnected, connecting, connected, reconnecting, error }

extension VpnStatusLive on VpnStatus {
  /// A tunnel is up or on its way up.
  bool get isLive =>
      this == VpnStatus.connected ||
      this == VpnStatus.connecting ||
      this == VpnStatus.reconnecting;
}

class VpnController {
  static const _maxRetryDelay = Duration(seconds: 30);

  /// How often the heartbeat looks at the clock. A probe goes out every
  /// [_probeEveryTicks] ticks.
  static const _heartbeatTick = Duration(seconds: 5);
  static const _probeEveryTicks = 3;

  final ValueNotifier<VpnStatus> status =
      ValueNotifier(VpnStatus.disconnected);
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  SshTunnel? _tunnel;

  /// On Android the tunnel lives in the VpnService, in Go.
  final AndroidVpnBridge _android = AndroidVpnBridge();
  Timer? _androidPoll;

  VpnController() {
    if (Platform.isAndroid) _attachAndroid();
  }

  /// On iOS none of the three fields above are ever set: the tunnel lives in a
  /// NetworkExtension, and this class only asks it to start and stop.
  final IosVpnBridge _ios = IosVpnBridge();
  StreamSubscription<IosTunnelStatus>? _iosStatusSub;

  List<ResolvedHop>? _lastHops;
  AppRoutingConfig? _lastRouting;
  bool _userDisconnected = false;
  int _retryCount = 0;
  Timer? _retryTimer;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  List<ConnectivityResult>? _lastConnectivity;
  Timer? _heartbeat;

  /// On macOS with the helper installed, the tunnel is vzhukhd's, and none
  /// of the fields above are used either. Without the helper, macOS falls
  /// back to the SOCKS proxy on [SshTunnel.socksPort].
  late final MacDaemonBackend? macDaemon =
      Platform.isMacOS ? (MacDaemonBackend(status, errorMessage)..attach()) : null;

  /// [ref] names what is being connected, so the macOS helper's config can
  /// be rebuilt after the app restarts.
  Future<void> connect(
    List<ResolvedHop> hops, {
    AppRoutingConfig? routing,
    ConnectionRef? ref,
  }) async {
    final mac = macDaemon;
    if (mac != null && await mac.isAvailable()) {
      _userDisconnected = true;
      _retryTimer?.cancel();
      _stopMonitors();
      await _cleanupTunnel();
      await mac.connect(hops, ref);
      return;
    }

    _retryTimer?.cancel();
    _retryTimer = null;
    _stopMonitors();
    _userDisconnected = true; // prevent onChainLost from scheduling reconnect during cleanup
    await _cleanupTunnel();

    _lastHops = hops;
    _lastRouting = routing;
    _userDisconnected = false;
    status.value = VpnStatus.connecting;
    errorMessage.value = null;

    if (Platform.isIOS) {
      // [routing] is deliberately not applied. iOS has no equivalent of
      // VpnService's allowed and disallowed package lists outside of MDM, so
      // the tunnel is always system-wide there.
      await _connectIos(hops);
      return;
    }

    if (Platform.isAndroid) {
      await _connectAndroid(hops, routing, ref);
      return;
    }

    try {
      // macOS without the helper: a SOCKS proxy on 2080 that apps are
      // pointed at by hand.
      _tunnel = SshTunnel(hops, onChainLost: _onChainLost);
      await _tunnel!.start();

      _retryCount = 0;
      status.value = VpnStatus.connected;
      _startConnectivityMonitor();
      _startHeartbeat();
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
    final mac = macDaemon;
    if (mac != null && mac.active) {
      await mac.disconnect();
      return;
    }
    if (status.value == VpnStatus.disconnected) return;
    _userDisconnected = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _stopMonitors();
    status.value = VpnStatus.disconnected;
    await _cleanup();
  }

  /// Hands the chain to the VpnService and then only watches. The service
  /// runs the tunnel in Go and reconnects on its own, after sleep and
  /// network changes included, so nothing here retries.
  Future<void> _connectAndroid(
    List<ResolvedHop> hops,
    AppRoutingConfig? routing,
    ConnectionRef? ref,
  ) async {
    try {
      await _android.start(hops, routing: routing, name: ref?.label);
      _watchAndroid();
    } catch (e) {
      errorMessage.value = e is PlatformException ? (e.message ?? e.code) : e.toString();
      status.value = VpnStatus.error;
    }
  }

  void _watchAndroid() {
    _androidPoll?.cancel();
    var everUp = false;
    _androidPoll = Timer.periodic(const Duration(seconds: 1), (_) async {
      final AndroidTunnelStatus s;
      try {
        s = await _android.status();
      } catch (_) {
        return;
      }
      switch (s.state) {
        case AndroidTunnelState.up:
          everUp = true;
          errorMessage.value = null;
          status.value = VpnStatus.connected;
        case AndroidTunnelState.connecting:
        case AndroidTunnelState.down:
          status.value = everUp ? VpnStatus.reconnecting : VpnStatus.connecting;
          errorMessage.value = s.error;
        case AndroidTunnelState.stopped:
          _androidPoll?.cancel();
          _androidPoll = null;
          status.value = VpnStatus.disconnected;
      }
    });
  }

  /// Picks up a tunnel the service kept running while the app was closed.
  Future<void> _attachAndroid() async {
    try {
      final s = await _android.status();
      if (s.state != AndroidTunnelState.stopped) {
        status.value = VpnStatus.connecting;
        _watchAndroid();
      }
    } catch (_) {}
  }

  /// Hands the whole chain to the extension and then only watches.
  ///
  /// No retry loop here on purpose: the extension reconnects itself, because
  /// when the connection drops with the phone in a pocket there is no app
  /// running to notice, and two things retrying would fight.
  Future<void> _connectIos(List<ResolvedHop> hops) async {
    _listenToIosStatus();

    try {
      await _ios.start(hops);
    } catch (e) {
      errorMessage.value = e.toString();
      status.value = VpnStatus.error;
    }
  }

  void _listenToIosStatus() {
    _iosStatusSub ??= _ios.status.listen((tunnelStatus) {
      switch (tunnelStatus) {
        case IosTunnelStatus.connecting:
          status.value = VpnStatus.connecting;
        case IosTunnelStatus.connected:
          errorMessage.value = null;
          status.value = VpnStatus.connected;
        case IosTunnelStatus.reasserting:
          // The extension is rebuilding the chain under a connection the
          // system still considers up.
          status.value = VpnStatus.reconnecting;
        case IosTunnelStatus.disconnecting:
        case IosTunnelStatus.disconnected:
        case IosTunnelStatus.invalid:
          status.value = VpnStatus.disconnected;
      }
    });
  }

  /// The chain under a running tunnel died. The listener, and on Android the
  /// TUN, stay up, so apps wait for the new chain instead of their traffic
  /// slipping out around the tunnel. The first attempt goes out at once.
  void _onChainLost(Object? reason) {
    if (_userDisconnected) return;
    _scheduleReconnect(delay: Duration.zero);
    errorMessage.value = reason?.toString();
  }

  /// Something suggests the chain may have died unnoticed: the network
  /// changed, or the machine just woke up.
  void _nudge() {
    if (_userDisconnected) return;
    if (_retryTimer?.isActive ?? false) {
      // Waiting out a backoff that was sized for a network that is gone.
      _retryCount = 0;
      _scheduleReconnect(delay: const Duration(seconds: 1));
      return;
    }
    if (status.value == VpnStatus.connected) _tunnel?.checkHealth();
  }

  /// Probes the chain regularly and notices sleep.
  ///
  /// Sleep is told by the wall clock: it keeps running while the machine is
  /// asleep, and the timer does not fire, so the first tick after waking sees
  /// a gap far longer than [_heartbeatTick]. That needs no platform code and
  /// covers a closed lid on macOS as well as Doze on Android.
  void _startHeartbeat() {
    _heartbeat?.cancel();
    var ticks = 0;
    var last = DateTime.now();
    _heartbeat = Timer.periodic(_heartbeatTick, (_) {
      final now = DateTime.now();
      final slept = now.difference(last) > _heartbeatTick * 3;
      last = now;
      ticks++;
      if (slept) {
        _nudge();
      } else if (ticks % _probeEveryTicks == 0 &&
          status.value == VpnStatus.connected) {
        _tunnel?.checkHealth();
      }
    });
  }

  void _stopMonitors() {
    _stopConnectivityMonitor();
    _heartbeat?.cancel();
    _heartbeat = null;
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

    // Strip VPN results — changes to the VPN layer are caused by our own tunnel.
    final physical = results.where((r) => r != ConnectivityResult.vpn).toList();

    final previous = _lastConnectivity;
    _lastConnectivity = physical;

    if (previous == null) return;

    // Any path update counts, not only a change of interface type: moving
    // between two Wi-Fi networks reports wifi both times, and the old socket
    // is just as dead. A probe on a healthy chain costs one round trip.
    final hasNetwork = physical.any((r) => r != ConnectivityResult.none);
    if (!hasNetwork) return;

    _nudge();
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
      final tunnel = _tunnel;
      if (tunnel != null && tunnel.isRunning) {
        await _rebuildChain(tunnel);
      } else {
        await _cleanupTunnel();
        await connect(_lastHops!, routing: _lastRouting);
      }
    });
  }

  /// Dials a new chain under a tunnel that is still listening.
  Future<void> _rebuildChain(SshTunnel tunnel) async {
    try {
      await tunnel.reconnect();
      if (_userDisconnected || !identical(tunnel, _tunnel)) return;
      _retryCount = 0;
      errorMessage.value = null;
      status.value = VpnStatus.connected;
    } catch (e) {
      if (_userDisconnected || !identical(tunnel, _tunnel)) return;
      _scheduleReconnect();
      errorMessage.value = e.toString();
    }
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
    if (Platform.isIOS) {
      try {
        await _ios.stop();
      } catch (_) {}
      return;
    }

    if (Platform.isAndroid) {
      _androidPoll?.cancel();
      _androidPoll = null;
      try {
        await _android.stop();
      } catch (_) {}
      return;
    }

    await _tunnel?.stop();
    _tunnel = null;
  }

  /// Sends edited rules to a running macOS tunnel.
  Future<void> applyRules() async => macDaemon?.applyRules();

  void dispose() {
    macDaemon?.dispose();
    _retryTimer?.cancel();
    _stopMonitors();
    _iosStatusSub?.cancel();
    _androidPoll?.cancel();
    status.dispose();
    errorMessage.dispose();
  }
}
