import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/daemon/traffic_analysis.dart';

TrafficRow row(String app, String host,
        {int port = 443, String action = 'route', String? route = 'r1', int errors = 0, int open = 0, int bytes = 0}) =>
    TrafficRow(
      app: app,
      host: host,
      port: port,
      network: 'tcp',
      action: action,
      route: action == 'route' ? route : null,
      conns: 1,
      open: open,
      errors: errors,
      download: bytes,
    );

void main() {
  final rows = [
    row('Waterfox', 'www.youtube.com', bytes: 500),
    row('Waterfox', 'i.ytimg.com', bytes: 300),
    row('Telegram', '149.154.167.41', bytes: 50, open: 1),
    row('Proxyman', 'gateway.icloud.com', action: 'system', bytes: 10),
    row('curl', 'api.example.com', action: 'direct', errors: 1),
  ];
  List<String> apps(TrafficQuery q, {String Function(TrafficDim, String)? names}) =>
      [for (final r in rows) if (q.matches(r, names: names)) r.app];

  test('the site is the last two labels, addresses stay whole', () {
    expect(siteOf('cdn.www.example.com'), 'example.com');
    expect(siteOf('example.com'), 'example.com');
    expect(siteOf('149.154.167.41'), '149.154.167.41');
  });

  test('terms are ANDed, commas within one are ORs, minus negates', () {
    expect(apps(TrafficQuery.parse('action:direct,system')), ['Proxyman', 'curl']);
    expect(apps(TrafficQuery.parse('app:waterfox host:*.ytimg.com')), ['Waterfox']);
    expect(apps(TrafficQuery.parse('-action:route')), ['Proxyman', 'curl']);
    expect(apps(TrafficQuery.parse('err')), ['curl']);
    expect(apps(TrafficQuery.parse('open')), ['Telegram']);
    expect(apps(TrafficQuery.parse('site:youtube.com')), ['Waterfox']);
    expect(apps(TrafficQuery.parse('youtube')), ['Waterfox']);
    expect(apps(TrafficQuery.parse('domain:icloud')), ['Proxyman']);
  });

  test('a route is found by the name the user sees', () {
    String names(TrafficDim d, String v) => d == TrafficDim.route && v == 'r1' ? 'home' : v;
    expect(apps(TrafficQuery.parse('route:home'), names: names), ['Waterfox', 'Waterfox', 'Telegram']);
  });

  test('a facet click adds its term, a second click takes it away', () {
    var q = TrafficQuery.parse('err');
    q = q.toggle(TrafficDim.app, 'curl');
    expect(q.text, 'err app:curl');
    expect(q.has(TrafficDim.app, 'curl'), isTrue);
    q = q.toggle(TrafficDim.app, 'curl');
    expect(q.text, 'err');
  });

  test('groups sum their rows and sort by bytes, keeping the path', () {
    final groups = const GroupTraffic()(rows, TrafficDim.app);
    expect([for (final g in groups) g.value], ['Waterfox', 'Telegram', 'Proxyman', 'curl']);
    expect(groups.first.totals.download, 800);
    expect(groups.first.totals.conns, 2);

    final sites = const GroupTraffic()(groups.first.rows, TrafficDim.site, parent: groups.first.path);
    expect(sites.map((g) => g.value), ['youtube.com', 'ytimg.com']);
    expect(sites.first.path, [(TrafficDim.app, 'Waterfox'), (TrafficDim.site, 'youtube.com')]);
    expect(sites.first.depth, 1);
  });
}
