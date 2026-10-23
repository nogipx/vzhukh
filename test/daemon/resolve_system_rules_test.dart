import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/daemon/daemon_models.dart';
import 'package:vzhukh/daemon/resolve_system_rules.dart';
import 'package:vzhukh/models/routing_rule.dart';

void main() {
  const resolve = ResolveSystemRules();
  const corp = DaemonVpn(
    id: 'exe:/Library/CorpVPN/corpvpnd',
    name: 'corpvpnd',
    interface: 'utun7',
    prefixes: ['10.100.0.0/14', '172.16.0.0/16'],
    domains: ['corp.example'],
  );

  RoutingRule system(String id, {List<String> domains = const [], List<String> cidrs = const [], List<String> apps = const []}) =>
      RoutingRule(id: id, name: id, domains: domains, cidrs: cidrs, apps: apps, action: RuleAction.system);

  test('rules the VPN serves name it, a lone gateway address goes direct', () {
    final rules = RoutingRules(rules: [
      system('by-domain', domains: ['*.corp.example']),
      system('by-net', cidrs: ['10.100.1.0/24']),
      system('wider-net', cidrs: ['172.16.0.0/12']),
      system('gateway', cidrs: ['203.0.113.7']),
      system('unknown-name', domains: ['example.com']),
      const RoutingRule(id: 'direct', name: 'direct', action: RuleAction.direct),
    ]);
    final result = resolve(rules, [corp]);
    expect(result.changed, 4);
    final byId = {for (final r in result.rules.rules) r.id: r};
    for (final id in ['by-domain', 'by-net', 'wider-net']) {
      expect(byId[id]!.action, RuleAction.vpn, reason: id);
      expect(byId[id]!.vpnId, corp.id);
      expect(byId[id]!.vpnName, 'corpvpnd');
    }
    expect(byId['gateway']!.action, RuleAction.direct);
    expect(byId['unknown-name']!.action, RuleAction.system);
    expect(byId['direct']!.action, RuleAction.direct);
  });

  test('with no VPN connected nothing can be told', () {
    final rules = RoutingRules(rules: [system('gateway', cidrs: ['203.0.113.7'])]);
    final result = resolve(rules, const []);
    expect(result.changed, 0);
    expect(identical(result.rules, rules), isTrue);
  });
}
