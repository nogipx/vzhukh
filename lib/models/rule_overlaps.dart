import 'dart:io' show InternetAddress;

import 'routing_rule.dart';

/// How a rule above gets in the way of one below.
enum OverlapKind {
  /// Everything the rule below matches, the one above takes first, and
  /// sends elsewhere: the rule below never applies.
  shadowed,

  /// Some of what the rule below matches, the one above takes first and
  /// sends elsewhere.
  partly,

  /// The rule above takes all of it and sends it the same way: the rule
  /// below changes nothing.
  redundant,
}

class RuleOverlap {
  final RoutingRule above;
  final OverlapKind kind;

  const RuleOverlap(this.above, this.kind);
}

/// Finds, for each rule in play, the rules in play above it that take
/// connections it would match. The first match wins, so those connections
/// never reach it.
///
/// Two rules overlap when one connection can match both: every criterion
/// both have shares a value, and a criterion only one of them has does not
/// count against it. A domain against an address cannot be told before the
/// name is looked up, so that pair counts as not shared. Only a partial
/// overlap on a criterion both name is reported; see [OverlapKind.partly].
class FindRuleOverlaps {
  const FindRuleOverlaps();

  /// Rule ids to what is in their way, the nearest rule above first.
  Map<String, List<RuleOverlap>> call(RoutingRules rules) {
    final active = [for (final r in rules.rules) if (rules.inPlay(r)) _Criteria(r)];
    final out = <String, List<RuleOverlap>>{};
    // Rules something above covers whole never take a connection, so they
    // are in nobody's way.
    final dead = <int>{};
    for (var i = 0; i < active.length; i++) {
      final below = active[i];
      for (var j = i - 1; j >= 0; j--) {
        if (dead.contains(j)) continue;
        final above = active[j];
        if (!above.overlaps(below)) continue;
        final same = _sameAction(above.rule, below.rule);
        final covers = above.covers(below);
        final kind = switch ((covers, same)) {
          (true, true) => OverlapKind.redundant,
          (true, false) => OverlapKind.shadowed,
          (false, true) => null,
          // An app rule and a domain rule can always meet, the app going to
          // that domain; said of every such pair it would say nothing.
          // Only rules naming the same thing are worth a word.
          (false, false) => above.sharesCriterion(below) ? OverlapKind.partly : null,
        };
        if (kind != null) (out[below.rule.id] ??= []).add(RuleOverlap(above.rule, kind));
        if (covers) dead.add(i);
      }
    }
    return out;
  }

  static bool _sameAction(RoutingRule a, RoutingRule b) =>
      a.action == b.action &&
      switch (a.action) {
        RuleAction.route => a.routeId == b.routeId,
        RuleAction.vpn => a.vpnId == b.vpnId,
        _ => true,
      };
}

/// A rule's criteria, parsed once.
class _Criteria {
  final RoutingRule rule;
  final List<_App> apps;
  final List<String> domains;
  final List<_Prefix> cidrs;
  final List<(int, int)> ports;

  _Criteria(this.rule)
      : apps = [for (final a in rule.apps) if (a.trim().isNotEmpty) _App(a.trim())],
        domains = [
          for (final d in rule.domains)
            if (_domain(d) case final n when n.isNotEmpty) n,
        ],
        cidrs = [
          for (final c in rule.cidrs)
            if (_Prefix.parse(c) case final p?) p,
        ],
        ports = [
          for (final p in rule.ports)
            if (_ports(p) case final r?) r,
        ];

  bool get _hasDestination => domains.isNotEmpty || cidrs.isNotEmpty;

  static String _domain(String d) {
    var n = d.trim().toLowerCase();
    if (n.startsWith('*.')) n = n.substring(2);
    if (n.endsWith('.')) n = n.substring(0, n.length - 1);
    return n;
  }

  static (int, int)? _ports(String spec) {
    final parts = spec.replaceAll(' ', '').split('-');
    final lo = int.tryParse(parts.first);
    final hi = parts.length > 1 ? int.tryParse(parts[1]) : lo;
    return lo == null || hi == null ? null : (lo, hi);
  }

  static bool _under(String name, String domain) => name == domain || name.endsWith('.$domain');

  /// One connection can match both.
  bool overlaps(_Criteria o) {
    if (apps.isNotEmpty && o.apps.isNotEmpty && !apps.any((a) => o.apps.any(a.overlaps))) return false;
    if (_hasDestination && o._hasDestination) {
      final byName = domains.any((a) => o.domains.any((b) => _under(a, b) || _under(b, a)));
      final byAddress = cidrs.any((a) => o.cidrs.any(a.overlaps));
      if (!byName && !byAddress) return false;
    }
    if (ports.isNotEmpty && o.ports.isNotEmpty &&
        !ports.any((a) => o.ports.any((b) => a.$1 <= b.$2 && b.$1 <= a.$2))) {
      return false;
    }
    return true;
  }

  /// Both name something of the same kind, and some of it is the same:
  /// one app, overlapping domains or addresses, a common port.
  bool sharesCriterion(_Criteria o) =>
      (apps.isNotEmpty && o.apps.isNotEmpty && apps.any((a) => o.apps.any(a.overlaps))) ||
      domains.any((a) => o.domains.any((b) => _under(a, b) || _under(b, a))) ||
      cidrs.any((a) => o.cidrs.any(a.overlaps)) ||
      ports.any((a) => o.ports.any((b) => a.$1 <= b.$2 && b.$1 <= a.$2));

  /// Every connection [o] matches, this matches too.
  bool covers(_Criteria o) {
    if (apps.isNotEmpty && (o.apps.isEmpty || !o.apps.every((b) => apps.any((a) => a.covers(b))))) return false;
    if (_hasDestination) {
      if (!o._hasDestination) return false;
      final names = o.domains.every((b) => domains.any((a) => _under(b, a)));
      final addresses = o.cidrs.every((b) => cidrs.any((a) => a.contains(b)));
      if (!names || !addresses) return false;
    }
    if (ports.isNotEmpty &&
        (o.ports.isEmpty || !o.ports.every((b) => ports.any((a) => a.$1 <= b.$1 && b.$2 <= a.$2)))) {
      return false;
    }
    return true;
  }
}

/// An app as a rule names it: a path, which covers everything under it, or
/// a name, the app's or the executable's.
class _App {
  final String? path;
  final String? name;

  _App(String entry)
      : path = entry.startsWith('/') ? entry.replaceAll(RegExp(r'/+$'), '') : null,
        name = entry.startsWith('/') ? null : entry.toLowerCase();

  /// The name an app at [path] goes by: its bundle's, without ".app".
  String? get _pathName {
    final p = path;
    if (p == null) return null;
    return p.split('/').last.replaceFirst(RegExp(r'\.app$', caseSensitive: false), '').toLowerCase();
  }

  static bool _within(String inner, String outer) => inner == outer || inner.startsWith('$outer/');

  bool overlaps(_App o) {
    if (path != null && o.path != null) return _within(path!, o.path!) || _within(o.path!, path!);
    if (name != null && o.name != null) return name == o.name;
    return (_pathName ?? o._pathName) == (name ?? o.name);
  }

  bool covers(_App o) {
    if (path != null) return o.path != null && _within(o.path!, path!);
    if (o.name != null) return name == o.name;
    return name == o._pathName;
  }
}

/// An address prefix, IPv4 or IPv6, as bytes and a length.
class _Prefix {
  final List<int> bytes;
  final int bits;

  _Prefix(this.bytes, this.bits);

  static _Prefix? parse(String text) {
    final parts = text.trim().split('/');
    final ip = InternetAddress.tryParse(parts.first);
    if (ip == null) return null;
    final max = ip.rawAddress.length * 8;
    final bits = parts.length > 1 ? int.tryParse(parts[1]) : max;
    if (bits == null || bits < 0 || bits > max) return null;
    return _Prefix(ip.rawAddress, bits);
  }

  bool _sameFirst(_Prefix o, int n) {
    if (bytes.length != o.bytes.length) return false;
    for (var i = 0; i < n; i++) {
      final mask = 0x80 >> (i % 8);
      if ((bytes[i ~/ 8] & mask) != (o.bytes[i ~/ 8] & mask)) return false;
    }
    return true;
  }

  bool overlaps(_Prefix o) => _sameFirst(o, bits < o.bits ? bits : o.bits);

  bool contains(_Prefix o) => o.bits >= bits && _sameFirst(o, bits);
}

/// One connection, or a sum of alike ones, as the helper saw it decided.
typedef SeenTraffic = ({String app, String? appPath, String host, int port, String? ruleId, int conns});

/// Connections a rule would have matched that a rule above it took and
/// sent elsewhere.
class SeenOverlap {
  final RoutingRule above;
  final int conns;

  /// A few of the hosts, for the user to recognise.
  final List<String> hosts;

  const SeenOverlap(this.above, this.conns, this.hosts);
}

/// The overlaps no rule's text can tell: an app rule above a domain rule
/// meets it only if the app goes to that domain. Recorded traffic says
/// whether it did. For each connection a rule decided, every rule in play
/// below it that would also have matched it, with another action, gets
/// it counted against the one that won.
class FindSeenOverlaps {
  const FindSeenOverlaps();

  /// Rule ids to the rules above that took their connections, most
  /// connections first.
  Map<String, List<SeenOverlap>> call(RoutingRules rules, Iterable<SeenTraffic> traffic) {
    final active = [for (final r in rules.rules) if (rules.inPlay(r)) _Criteria(r)];
    final at = {for (final (i, c) in active.indexed) c.rule.id: i};
    final counts = <String, Map<String, ({int conns, Set<String> hosts})>>{};
    for (final t in traffic) {
      final i = at[t.ruleId];
      if (i == null) continue;
      final winner = active[i];
      for (final below in active.skip(i + 1)) {
        if (FindRuleOverlaps._sameAction(winner.rule, below.rule) || !below.matches(t)) continue;
        final byWinner = counts[below.rule.id] ??= {};
        final prev = byWinner[winner.rule.id] ?? (conns: 0, hosts: <String>{});
        byWinner[winner.rule.id] = (conns: prev.conns + t.conns, hosts: prev.hosts..add(t.host));
      }
    }
    final rulesById = {for (final c in active) c.rule.id: c.rule};
    return {
      for (final e in counts.entries)
        e.key: [
          for (final w in e.value.entries) SeenOverlap(rulesById[w.key]!, w.value.conns, w.value.hosts.take(3).toList()),
        ]..sort((a, b) => b.conns.compareTo(a.conns)),
    };
  }
}

extension on _Criteria {
  /// Whether the daemon would have decided [t] by this rule, as far as what
  /// was recorded of it tells.
  bool matches(SeenTraffic t) {
    if (apps.isNotEmpty) {
      final name = t.app.toLowerCase();
      final path = t.appPath;
      final hit = apps.any((a) => a.path != null
          ? path != null && _App._within(path, a.path!)
          : a.name == name);
      if (!hit) return false;
    }
    if (_hasDestination) {
      final host = _Criteria._domain(t.host);
      final ip = _Prefix.parse(t.host);
      final hit = domains.any((d) => _Criteria._under(host, d)) || (ip != null && cidrs.any((c) => c.contains(ip)));
      if (!hit) return false;
    }
    if (ports.isNotEmpty && !ports.any((p) => p.$1 <= t.port && t.port <= p.$2)) return false;
    return true;
  }
}
