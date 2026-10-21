import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/daemon/build_daemon_config.dart';
import 'package:vzhukh/models/routing_rule.dart';
import 'package:vzhukh/models/server.dart';
import 'package:vzhukh/models/ssh_identity.dart';
import 'package:vzhukh/models/tunnel_route.dart';
import 'package:vzhukh/storage/route_repository.dart';

class _Routes implements RouteRepository {
  final List<TunnelRoute> routes;
  _Routes(this.routes);
  @override
  Future<List<TunnelRoute>> getRoutes() async => routes;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ResolvedHop _hop(String host) => ResolvedHop(
      server: Server(id: host, host: host, port: 22, nickname: host),
      identity: SshIdentity(
        id: 'c-$host',
        serverId: host,
        username: 'u',
        authType: SshAuthType.privateKey,
        isAdmin: false,
        privateKeyPem: 'KEY-$host',
      ),
    );

const _home = TunnelRoute(id: 'home', label: 'Home', hops: [RouteHop(serverId: 'h', connectionId: 'c')]);
const _work = TunnelRoute(id: 'work', label: 'Work', hops: [RouteHop(serverId: 'w', connectionId: 'c')]);

void main() {
  final resolved = <String>[];
  Future<List<ResolvedHop>> resolve(TunnelRoute r) async {
    resolved.add(r.id);
    return [_hop('${r.id}.example')];
  }

  setUp(resolved.clear);

  test('the connected route is always sent and is the default', () async {
    final cfg = await BuildDaemonConfig(_Routes([_home]), resolve)(
      connected: [_hop('a.example')],
      connectedLabel: 'A',
      rules: const RoutingRules(),
    );
    final routes = cfg['routes'] as List;
    expect(routes, hasLength(1));
    expect(routes.first['id'], BuildDaemonConfig.connectedRouteId);
    expect(routes.first['hops'].first['privateKeyPem'], 'KEY-a.example');
    expect(cfg['rules']['default'], {'action': 'route', 'route': 'connected'});
    expect(resolved, isEmpty);
  });

  test('rules map onto daemon actions, and only used routes are dialed', () async {
    final cfg = await BuildDaemonConfig(_Routes([_home, _work]), resolve)(
      connected: [_hop('home.example')],
      connectedLabel: 'Home',
      connectedTunnelRouteId: 'home',
      rules: const RoutingRules(
        defaultAction: DefaultAction.direct,
        rules: [
          RoutingRule(id: '1', name: 'slack', apps: ['Slack'], action: RuleAction.route, routeId: 'work'),
          RoutingRule(id: '2', name: 'self', domains: ['x.com'], action: RuleAction.route, routeId: 'home'),
          RoutingRule(id: '3', name: 'yt', domains: ['youtube.com'], action: RuleAction.connectedRoute),
          RoutingRule(id: '4', name: 'ads', domains: ['ads.net'], action: RuleAction.block),
          RoutingRule(id: '5', name: 'lan', cidrs: ['10.0.0.0/8'], action: RuleAction.direct, enabled: false),
        ],
      ),
    );

    final routes = (cfg['routes'] as List).map((r) => r['id']).toList();
    expect(routes, ['connected', 'work'], reason: 'home is the connected one, not a second chain');
    expect(resolved, ['work']);

    final rules = cfg['rules']['rules'] as List;
    expect(rules[0], containsPair('route', 'work'));
    expect(rules[1], containsPair('route', 'connected'));
    expect(rules[2], containsPair('route', 'connected'));
    expect(rules[3], containsPair('action', 'block'));
    expect(rules[3].containsKey('route'), isFalse);
    expect(rules[4], containsPair('disabled', true));
    expect(cfg['rules']['default'], {'action': 'direct'});
  });

  test('a rule naming a deleted route is an error, not a silent default', () async {
    expect(
      () => BuildDaemonConfig(_Routes([]), resolve)(
        connected: [_hop('a.example')],
        connectedLabel: 'A',
        rules: const RoutingRules(rules: [
          RoutingRule(id: '1', name: 'gone', action: RuleAction.route, routeId: 'deleted'),
        ]),
      ),
      throwsException,
    );
  });

  test('system rules and bypass reach the daemon', () async {
    final cfg = await BuildDaemonConfig(_Routes([]), resolve)(
      connected: [_hop('a.example')],
      connectedLabel: 'A',
      rules: const RoutingRules(
        bypass: ['203.0.113.192'],
        rules: [RoutingRule(id: 'c', name: 'corp', domains: ['corp.example'], action: RuleAction.system)],
      ),
    );
    expect(cfg['bypass'], ['203.0.113.192']);
    expect((cfg['rules']['rules'] as List).single, containsPair('action', 'system'));
  });

  test('rulesSection carries the enabled flag and routesUsed ignores disabled rules', () {
    const rules = RoutingRules(rules: [
      RoutingRule(id: 'a', name: 'on', domains: ['x.com'], action: RuleAction.direct),
      RoutingRule(id: 'b', name: 'off', domains: ['y.com'], action: RuleAction.route, routeId: 'work', enabled: false),
    ]);
    final section = BuildDaemonConfig.rulesSection(rules);
    final list = section['rules'] as List;
    expect(list[0]['disabled'], false);
    expect(list[1]['disabled'], true);
    expect(BuildDaemonConfig.routesUsed(rules), isEmpty);
    expect(
      BuildDaemonConfig.routesUsed(RoutingRules(rules: [rules.rules[1].copyWith(enabled: true)])),
      {'work'},
    );
  });

  test('rules survive a round trip through JSON', () {
    const rules = RoutingRules(
      defaultAction: DefaultAction.direct,
      bypass: ['10.0.0.0/8'],
      rules: [
        RoutingRule(
          id: '1',
          name: 'n',
          apps: ['/Applications/Telegram.app'],
          domains: ['t.me'],
          cidrs: ['1.2.3.0/24'],
          ports: ['443', '8000-8999'],
          action: RuleAction.route,
          routeId: 'work',
          enabled: false,
        ),
      ],
    );
    final back = RoutingRules.fromJson(rules.toJson());
    expect(back.toJson(), rules.toJson());
  });
}
