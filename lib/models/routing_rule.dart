import 'package:flutter/foundation.dart';

/// What happens to a connection a rule matches. Mirrors the daemon's
/// router.Action, plus [connectedRoute], which the app turns into whichever
/// route the user pressed Connect on.
///
/// [direct] goes out of Wi-Fi or Ethernet and never into another VPN.
/// [vpn] goes into the VPN [RoutingRule.vpnId] names, a corporate one
/// typically: its names get real answers from that VPN's resolvers, and
/// while it is down the connection is refused.
///
/// [system] leaves matches to macOS and whatever else is installed. It is
/// what rules said before a VPN could be named, and is turned into [vpn] or
/// [direct] once the helper can tell which VPN was meant.
enum RuleAction { connectedRoute, route, direct, vpn, block, system }

/// One macOS routing rule.
///
/// Every criterion that is set has to match; within a criterion any entry
/// may. Rules are tried top to bottom and the first match wins. This is the
/// daemon's model one to one (go/tun2socks/internal/router), so what the
/// user writes is what decides the connection.
@immutable
class RoutingRule {
  final String id;
  final String name;

  /// App bundles ("/Applications/Telegram.app"), executables
  /// ("/usr/bin/curl") or bare names ("curl").
  final List<String> apps;

  /// "example.com" also covers every name under it.
  final List<String> domains;
  final List<String> cidrs;

  /// "443" or "8000-8999".
  final List<String> ports;

  final RuleAction action;

  /// The [TunnelRoute] id for [RuleAction.route].
  final String? routeId;

  /// The VPN for [RuleAction.vpn], as the helper identifies it, and its
  /// name for showing while it is not connected.
  final String? vpnId;
  final String? vpnName;

  final bool enabled;

  const RoutingRule({
    required this.id,
    required this.name,
    this.apps = const [],
    this.domains = const [],
    this.cidrs = const [],
    this.ports = const [],
    required this.action,
    this.routeId,
    this.vpnId,
    this.vpnName,
    this.enabled = true,
  });

  bool get matchesEverything =>
      apps.isEmpty && domains.isEmpty && cidrs.isEmpty && ports.isEmpty;

  RoutingRule copyWith({
    String? name,
    List<String>? apps,
    List<String>? domains,
    List<String>? cidrs,
    List<String>? ports,
    RuleAction? action,
    String? routeId,
    bool clearRouteId = false,
    String? vpnId,
    String? vpnName,
    bool clearVpn = false,
    bool? enabled,
  }) =>
      RoutingRule(
        id: id,
        name: name ?? this.name,
        apps: apps ?? this.apps,
        domains: domains ?? this.domains,
        cidrs: cidrs ?? this.cidrs,
        ports: ports ?? this.ports,
        action: action ?? this.action,
        routeId: clearRouteId ? null : routeId ?? this.routeId,
        vpnId: clearVpn ? null : vpnId ?? this.vpnId,
        vpnName: clearVpn ? null : vpnName ?? this.vpnName,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'apps': apps,
        'domains': domains,
        'cidrs': cidrs,
        'ports': ports,
        'action': action.name,
        if (routeId != null) 'routeId': routeId,
        if (vpnId != null) 'vpnId': vpnId,
        if (vpnName != null) 'vpnName': vpnName,
        'enabled': enabled,
      };

  factory RoutingRule.fromJson(Map<String, dynamic> json) => RoutingRule(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        apps: List<String>.from(json['apps'] as List? ?? const []),
        domains: List<String>.from(json['domains'] as List? ?? const []),
        cidrs: List<String>.from(json['cidrs'] as List? ?? const []),
        ports: List<String>.from(json['ports'] as List? ?? const []),
        action: RuleAction.values.byName(json['action'] as String),
        routeId: json['routeId'] as String?,
        vpnId: json['vpnId'] as String?,
        vpnName: json['vpnName'] as String?,
        enabled: json['enabled'] as bool? ?? true,
      );
}

/// What applies when no rule matches.
enum DefaultAction { connectedRoute, direct }

@immutable
class RoutingRules {
  final List<RoutingRule> rules;
  final DefaultAction defaultAction;

  /// Addresses, prefixes or host names kept out of the tunnel by the
  /// routing table itself: another VPN's gateway, whose own connection must
  /// never pass through vzhukh.
  final List<String> bypass;

  const RoutingRules({
    this.rules = const [],
    this.defaultAction = DefaultAction.connectedRoute,
    this.bypass = const [],
  });

  RoutingRules copyWith({
    List<RoutingRule>? rules,
    DefaultAction? defaultAction,
    List<String>? bypass,
  }) =>
      RoutingRules(
        rules: rules ?? this.rules,
        defaultAction: defaultAction ?? this.defaultAction,
        bypass: bypass ?? this.bypass,
      );

  Map<String, dynamic> toJson() => {
        'rules': rules.map((r) => r.toJson()).toList(),
        'defaultAction': defaultAction.name,
        'bypass': bypass,
      };

  factory RoutingRules.fromJson(Map<String, dynamic> json) => RoutingRules(
        rules: (json['rules'] as List? ?? const [])
            .map((r) => RoutingRule.fromJson(Map<String, dynamic>.from(r as Map)))
            .toList(),
        defaultAction: DefaultAction.values
            .byName(json['defaultAction'] as String? ?? 'connectedRoute'),
        bypass: List<String>.from(json['bypass'] as List? ?? const []),
      );
}
