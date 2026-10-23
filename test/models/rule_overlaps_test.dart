import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/models/routing_rule.dart';
import 'package:vzhukh/models/rule_overlaps.dart';

RoutingRule _r(
  String id,
  RuleAction action, {
  List<String> apps = const [],
  List<String> domains = const [],
  List<String> cidrs = const [],
  List<String> ports = const [],
  bool enabled = true,
}) =>
    RoutingRule(id: id, name: id, action: action, apps: apps, domains: domains, cidrs: cidrs, ports: ports, enabled: enabled);

Map<String, List<String>> _find(List<RoutingRule> rules) => {
      for (final e in const FindRuleOverlaps()(RoutingRules(rules: rules)).entries)
        e.key: [for (final o in e.value) '${o.above.id}:${o.kind.name}'],
    };

void main() {
  test('a wider domain above, sending elsewhere, shadows a narrower one', () {
    expect(_find([
      _r('google', RuleAction.connectedRoute, domains: ['google.com']),
      _r('mail', RuleAction.direct, domains: ['mail.google.com']),
    ]), {'mail': ['google:shadowed']});
  });

  test('the other way round nothing is in the way', () {
    expect(_find([
      _r('mail', RuleAction.direct, domains: ['mail.google.com']),
      _r('google', RuleAction.connectedRoute, domains: ['*.google.com']),
    ]), {'google': ['mail:partly']});
  });

  test('an app rule and a domain rule meet only hypothetically: not reported', () {
    expect(_find([
      _r('telegram', RuleAction.direct, apps: ['Telegram']),
      _r('tme', RuleAction.connectedRoute, domains: ['t.me']),
    ]), isEmpty);
  });

  test('the same app with different ports is partly taken', () {
    expect(_find([
      _r('web', RuleAction.direct, apps: ['Telegram'], ports: ['443']),
      _r('all', RuleAction.connectedRoute, apps: ['Telegram']),
    ]), {'all': ['web:partly']});
  });

  test('a rule with no criteria shadows everything below it', () {
    expect(_find([
      _r('all', RuleAction.direct),
      _r('a', RuleAction.block, domains: ['example.com']),
      _r('b', RuleAction.direct, ports: ['22']),
    ]), {
      'a': ['all:shadowed'],
      'b': ['all:redundant'],
    });
  });

  test('rules that cannot meet are left alone', () {
    expect(_find([
      _r('a', RuleAction.direct, domains: ['example.com']),
      _r('b', RuleAction.block, domains: ['example.org']),
      _r('c', RuleAction.block, cidrs: ['10.0.0.0/8'], ports: ['443']),
      _r('d', RuleAction.direct, cidrs: ['10.1.0.0/16'], ports: ['22']),
      _r('e', RuleAction.direct, apps: ['Safari'], domains: ['example.net']),
      // A domain against an address cannot be told: not counted.
      _r('f', RuleAction.block, cidrs: ['93.184.216.34']),
    ]), isEmpty);
  });

  test('addresses, apps by path and ports', () {
    // host never applies, so it is in nobody's way below.
    expect(_find([
      _r('lan', RuleAction.direct, cidrs: ['10.0.0.0/8']),
      _r('host', RuleAction.block, cidrs: ['10.1.2.3']),
      _r('bundle', RuleAction.direct, apps: ['/Applications/Telegram.app']),
      _r('name', RuleAction.block, apps: ['telegram'], ports: ['443', '8000-8999']),
      _r('range', RuleAction.direct, ports: ['8080']),
    ]), {
      'host': ['lan:shadowed'],
      'name': ['bundle:partly'],
      'range': ['name:partly'],
    });
  });

  test('rules out of play neither shadow nor are shadowed', () {
    expect(_find([
      _r('all', RuleAction.direct, enabled: false),
      _r('a', RuleAction.block, domains: ['example.com']),
    ]), isEmpty);
  });

  test('traffic shows what an app rule above took from a domain rule below', () {
    final rules = RoutingRules(rules: [
      _r('telegram', RuleAction.direct, apps: ['Telegram']),
      _r('lan', RuleAction.block, cidrs: ['10.0.0.0/8']),
      _r('tme', RuleAction.connectedRoute, domains: ['t.me']),
      _r('same', RuleAction.direct, domains: ['t.me']),
    ]);
    SeenTraffic t(String app, String host, int port, String rule, int conns) =>
        (app: app, appPath: null, host: host, port: port, ruleId: rule, conns: conns);
    final seen = const FindSeenOverlaps()(rules, [
      t('Telegram', 't.me', 443, 'telegram', 5),
      t('Telegram', 'cdn.t.me', 443, 'telegram', 2),
      t('Telegram', '149.154.167.41', 443, 'telegram', 9),
      t('Safari', '10.1.2.3', 80, 'lan', 1),
    ]);
    // Only tme: same sends it the same way, lan never matched a name, and
    // 149.154.167.41 is no domain of tme's.
    expect(seen.keys, ['tme']);
    expect(seen['tme']!.single.above.id, 'telegram');
    expect(seen['tme']!.single.conns, 7);
    expect(seen['tme']!.single.hosts, ['t.me', 'cdn.t.me']);
  });
}
