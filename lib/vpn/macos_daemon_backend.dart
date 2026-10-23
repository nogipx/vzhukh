import 'dart:async';

import 'package:flutter/foundation.dart';

import '../daemon/build_daemon_config.dart';
import '../daemon/daemon_client.dart';
import '../daemon/daemon_models.dart';
import '../models/tunnel_route.dart';
import '../storage/helper_settings.dart';
import '../storage/route_repository.dart';
import '../storage/routing_rules_repository.dart';
import '../storage/server_repository.dart';
import 'connection_ref.dart';
import 'route_resolver.dart';
import 'vpn_controller.dart';

/// The macOS tunnel when the helper is installed: vzhukhd owns the utun and
/// the SSH chains, and this class only tells it what to do and watches.
///
/// The tunnel no longer depends on the app. Quitting it leaves traffic
/// flowing, and the next launch finds the daemon running and picks the
/// status up from there; the daemon also does all the reconnecting, after
/// sleep included, without the app being involved.
class MacDaemonBackend {
  final ValueNotifier<VpnStatus> _status;
  final ValueNotifier<String?> _error;
  final DaemonClient client;

  /// The daemon's last status, null while it cannot be reached.
  final ValueNotifier<DaemonStatus?> daemonStatus = ValueNotifier(null);

  final _rules = RoutingRulesRepository();
  final _routes = RouteRepository();
  final _servers = ServerRepository();
  final _refs = ConnectionRefStore();

  /// Whether the tunnel currently belongs to the daemon.
  bool active = false;

  bool _starting = false;
  bool _everUp = false;
  ConnectionRef? _ref;
  List<ResolvedHop>? _hops;
  Timer? _poll;

  MacDaemonBackend(this._status, this._error, {DaemonClient? client})
      : client = client ?? DaemonClient();

  void attach() {
    _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  Future<bool> isAvailable() async => await client.version() != null;

  Future<void> _tick() async {
    final DaemonStatus s;
    try {
      s = await client.status();
    } catch (_) {
      daemonStatus.value = null;
      if (active && !_starting) {
        // launchd restarts a daemon that died; until then say so.
        _status.value = VpnStatus.reconnecting;
        _error.value = 'Network helper is not responding';
      }
      return;
    }
    daemonStatus.value = s;
    if (_starting) return;

    if (s.state == DaemonState.running && !active) {
      // Left running by a previous launch of the app.
      active = true;
      _ref = await _refs.load();
    }
    if (active) _reflect(s);
  }

  void _reflect(DaemonStatus s) {
    switch (s.state) {
      case DaemonState.running:
        final route = s.route(BuildDaemonConfig.connectedRouteId);
        if (route?.state == RouteState.up) {
          _everUp = true;
          _status.value = VpnStatus.connected;
          _error.value = null;
        } else {
          _status.value =
              _everUp ? VpnStatus.reconnecting : VpnStatus.connecting;
          _error.value = route?.error;
        }
      case DaemonState.idle:
        active = false;
        _status.value = VpnStatus.disconnected;
      case DaemonState.error:
        active = false;
        _status.value = VpnStatus.error;
        _error.value = s.error;
    }
  }

  Future<Map<String, dynamic>> _config(List<ResolvedHop> hops, ConnectionRef? ref) async {
    return BuildDaemonConfig(_routes, RouteResolver(_servers).resolve)(
      connected: hops,
      connectedLabel: ref?.label ?? hops.last.server.nickname,
      connectedTunnelRouteId: ref?.routeId,
      rules: await _rules.effective(),
      leaveOtherVpns: await const HelperSettings().leaveOtherVpns(),
    );
  }

  Future<void> connect(List<ResolvedHop> hops, ConnectionRef? ref) async {
    _starting = true;
    active = true;
    _everUp = false;
    _hops = hops;
    _ref = ref;
    _status.value = VpnStatus.connecting;
    _error.value = null;
    try {
      if (ref != null) await _refs.save(ref);
      final s = await client.start(await _config(hops, ref));
      daemonStatus.value = s;
      _starting = false;
      _reflect(s);
    } catch (e) {
      _starting = false;
      active = false;
      _status.value = VpnStatus.error;
      _error.value = e.toString();
    }
  }

  Future<void> disconnect() async {
    active = false;
    _hops = null;
    _status.value = VpnStatus.disconnected;
    await _refs.clear();
    try {
      daemonStatus.value = await client.stop();
    } catch (e) {
      _error.value = e.toString();
    }
  }

  /// Sends the current rules to a running tunnel. They apply from the next
  /// connection on; the SSH chains are redialed only if the set of routes
  /// the rules use changed.
  ///
  /// Only the rules go over when the routes they use are ones the tunnel
  /// already has, which is the usual case: no keys, no reconnect, and
  /// nothing here that has to remember how the tunnel was started. It
  /// goes by what the daemon reports, not by this object's own idea of
  /// whether it owns the tunnel.
  Future<void> applyRules() async {
    final status = await client.status();
    if (status.state != DaemonState.running) return;
    final ref = _ref ?? await _refs.load();
    final rules = await _rules.effective();
    final needed = BuildDaemonConfig.routesUsed(rules, connectedTunnelRouteId: ref?.routeId);
    final have = status.routes.map((r) => r.id).toSet();
    if (have.containsAll(needed)) {
      daemonStatus.value = await client.setRules(
          BuildDaemonConfig.rulesSection(rules, connectedTunnelRouteId: ref?.routeId));
      return;
    }

    // A rule now uses a route the tunnel does not have: the whole config
    // goes again, keys included.
    var hops = _hops;
    if (hops == null) {
      if (ref == null) {
        throw Exception('Reconnect once to apply rules to this tunnel');
      }
      hops = await ResolveConnectionRef(_servers, _routes)(ref);
      _hops = hops;
    }
    daemonStatus.value = await client.start(await _config(hops, ref));
  }

  void dispose() {
    _poll?.cancel();
    client.close();
    daemonStatus.dispose();
  }
}
