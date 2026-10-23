import 'dart:io' show InternetAddress, InternetAddressType;

import '../models/routing_rule.dart';
import 'daemon_models.dart';

/// Turns rules that left connections to macOS into ones that say where
/// they go, now that a VPN can be named.
///
/// A rule becomes [RuleAction.vpn] when one of its addresses lies in a
/// network a connected VPN routes, or one of its domains is a VPN's DNS
/// domain. A rule of addresses alone that no VPN serves was another VPN's
/// gateway, kept out of the tunnel: it becomes [RuleAction.direct]. The rest
/// stay as they are; with no VPN connected nothing can be told, and nothing
/// changes.
class ResolveSystemRules {
  const ResolveSystemRules();

  /// The rules with every resolvable [RuleAction.system] rule replaced, and
  /// how many were. [rules] itself when none was.
  ({RoutingRules rules, int changed}) call(RoutingRules rules, List<DaemonVpn> vpns) {
    if (vpns.isEmpty || !rules.rules.any((r) => r.action == RuleAction.system)) {
      return (rules: rules, changed: 0);
    }
    final out = [
      for (final rule in rules.rules) rule.action == RuleAction.system ? _resolve(rule, vpns) : rule,
    ];
    var changed = 0;
    for (var i = 0; i < out.length; i++) {
      if (!identical(out[i], rules.rules[i])) changed++;
    }
    return (rules: changed == 0 ? rules : rules.copyWith(rules: out), changed: changed);
  }

  static RoutingRule _resolve(RoutingRule rule, List<DaemonVpn> vpns) {
    final vpn = _serving(rule, vpns);
    if (vpn != null) return rule.copyWith(action: RuleAction.vpn, vpnId: vpn.id, vpnName: vpn.name);
    if (rule.apps.isEmpty && rule.domains.isEmpty && rule.cidrs.isNotEmpty) {
      return rule.copyWith(action: RuleAction.direct);
    }
    return rule;
  }

  static DaemonVpn? _serving(RoutingRule rule, List<DaemonVpn> vpns) {
    for (final vpn in vpns) {
      final nets = vpn.prefixes.map(_Net.parse).nonNulls.toList();
      for (final cidr in rule.cidrs) {
        final net = _Net.parse(cidr);
        if (net != null && nets.any((n) => n.overlaps(net))) return vpn;
      }
      for (final domain in rule.domains) {
        final d = _bare(domain);
        if (vpn.domains.any((v) => d == v || d.endsWith('.$v'))) return vpn;
      }
    }
    return null;
  }

  static String _bare(String domain) {
    var d = domain.trim().toLowerCase();
    if (d.startsWith('*.')) d = d.substring(2);
    if (d.endsWith('.')) d = d.substring(0, d.length - 1);
    return d;
  }
}

/// An IPv4 prefix, enough to tell whether two overlap.
class _Net {
  final int base;
  final int bits;

  const _Net(this.base, this.bits);

  static _Net? parse(String text) {
    final [addr, ...rest] = text.trim().split('/');
    final ip = InternetAddress.tryParse(addr);
    if (ip == null || ip.type != InternetAddressType.IPv4) return null;
    final bits = rest.isEmpty ? 32 : int.tryParse(rest.first);
    if (bits == null || bits < 0 || bits > 32) return null;
    final value = ip.rawAddress.fold<int>(0, (acc, b) => acc << 8 | b);
    return _Net(value & _mask(bits), bits);
  }

  static int _mask(int bits) => bits == 0 ? 0 : (0xffffffff << (32 - bits)) & 0xffffffff;

  bool overlaps(_Net other) {
    final mask = _mask(bits < other.bits ? bits : other.bits);
    return base & mask == other.base & mask;
  }
}
