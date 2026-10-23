import '../models/routing_rule.dart';
import '../models/tunnel_route.dart';
import '../storage/route_repository.dart';
import '../sync/received_items.dart';

/// Turns what the user configured into the config vzhukhd starts with
/// (daemon.Config in go/tun2socks/internal/daemon/daemon.go).
///
/// The route the user connected with is always sent, as [connectedRouteId].
/// Every other saved route a rule names is sent as well, under its own id,
/// so the daemon dials it up front. A rule naming the very route that is
/// connected is pointed at the connected one rather than opening a second
/// chain to the same server.
class BuildDaemonConfig {
  static const connectedRouteId = 'connected';

  final RouteRepository _routes;
  final Future<List<ResolvedHop>> Function(TunnelRoute) _resolve;

  /// [resolve] is normally RouteResolver.resolve.
  const BuildDaemonConfig(this._routes, this._resolve);

  Future<Map<String, dynamic>> call({
    required List<ResolvedHop> connected,
    required String connectedLabel,
    String? connectedTunnelRouteId,
    required RoutingRules rules,
    bool leaveOtherVpns = false,
  }) async {
    final routes = <Map<String, dynamic>>[
      {
        'id': connectedRouteId,
        'name': connectedLabel,
        'hops': connected.map(_hop).toList(),
      },
    ];

    final saved = await _routes.getRoutes();
    final wanted = routesUsed(rules, connectedTunnelRouteId: connectedTunnelRouteId);

    for (final id in wanted) {
      final route = saved.where((r) => r.id == id).firstOrNull ?? ReceivedItems.instance.route(id);
      if (route == null) {
        throw Exception('A rule uses a route that is not available');
      }
      routes.add({
        'id': route.id,
        'name': route.label,
        'hops': (await _resolve(route)).map(_hop).toList(),
      });
    }

    return {
      'routes': routes,
      if (rules.bypass.isNotEmpty) 'bypass': rules.bypass,
      if (leaveOtherVpns) 'capture': {'leaveVpns': true},
      'rules': rulesSection(rules, connectedTunnelRouteId: connectedTunnelRouteId),
    };
  }

  /// The routes the enabled rules send traffic through, besides the
  /// connected one.
  static Set<String> routesUsed(RoutingRules rules, {String? connectedTunnelRouteId}) => {
        for (final rule in rules.rules)
          if (rule.enabled && rule.action == RuleAction.route)
            _routeFor(rule, connectedTunnelRouteId),
      }..remove(connectedRouteId);

  static String _routeFor(RoutingRule rule, String? connectedTunnelRouteId) {
    if (rule.action == RuleAction.connectedRoute ||
        rule.routeId == null ||
        rule.routeId == connectedTunnelRouteId) {
      return connectedRouteId;
    }
    return rule.routeId!;
  }

  /// The rules part of the config on its own: what the daemon's "rules"
  /// method takes to change the rules of a running tunnel.
  static Map<String, dynamic> rulesSection(RoutingRules rules, {String? connectedTunnelRouteId}) {
    Map<String, dynamic> decision(RoutingRule rule) => switch (rule.action) {
          RuleAction.connectedRoute ||
          RuleAction.route =>
            {'action': 'route', 'route': _routeFor(rule, connectedTunnelRouteId)},
          RuleAction.direct => {'action': 'direct'},
          RuleAction.vpn => {'action': 'vpn', 'vpn': rule.vpnId},
          RuleAction.block => {'action': 'block'},
          RuleAction.system => {'action': 'system'},
        };

    return {
      'rules': [
        for (final rule in rules.rules)
          {
            'id': rule.id,
            'name': rule.name,
            'apps': rule.apps,
            'domains': rule.domains,
            'cidrs': rule.cidrs,
            'ports': rule.ports,
            ...decision(rule),
            'disabled': !rule.enabled,
          },
      ],
      'default': switch (rules.defaultAction) {
        DefaultAction.connectedRoute => {
            'action': 'route',
            'route': connectedRouteId,
          },
        DefaultAction.direct => {'action': 'direct'},
      },
    };
  }

  Map<String, dynamic> _hop(ResolvedHop hop) => {
        'host': hop.server.host,
        'port': hop.server.port,
        'username': hop.identity.username,
        if (hop.identity.password != null) 'password': hop.identity.password,
        if (hop.identity.privateKeyPem != null)
          'privateKeyPem': hop.identity.privateKeyPem,
      };
}
