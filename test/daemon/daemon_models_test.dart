import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/daemon/daemon_models.dart';

// JSON as vzhukhd encodes it (go/tun2socks/internal/daemon and flows).
const _status = '''
{"version":"1","state":"running","since":"2026-10-20T05:30:25.728882+03:00",
 "routes":[{"id":"connected","name":"Home","state":"up","since":"2026-10-20T05:30:26Z","server":"1.2.3.4","hops":2,"retries":1},
           {"id":"work","state":"connecting","error":"dial: timeout","since":"2026-10-20T05:30:26Z","server":"5.6.7.8","hops":1,"retries":3}],
 "platform":{"interface":"en0","tunnel":"utun7","upstreamDns":["192.168.1.1","1.1.1.1"]},"rules":4}
''';

const _flows = '''
{"seq":7,
 "active":[{"id":9,"network":"tcp","started":"2026-10-20T05:30:25.728882+03:00","open":true,"pid":42,"app":"Telegram",
            "appPath":"/Applications/Telegram.app","exePath":"/Applications/Telegram.app/Contents/MacOS/Telegram",
            "domain":"t.me","domainSource":"dns","destination":"198.18.0.5:443","dialed":"t.me:443",
            "action":"route","route":"connected","upload":10,"download":2000}],
 "closed":[{"id":3,"network":"udp","started":"2026-10-20T05:30:25Z","ended":"2026-10-20T05:30:26Z","open":false,
            "destination":"8.8.8.8:443","action":"route","route":"connected","upload":0,"download":0,
            "error":"UDP cannot go through an SSH route"}],
 "totals":{"connections":12,"upload":100,"download":5000}}
''';

void main() {
  test('status', () {
    final s = DaemonStatus.fromJson(jsonDecode(_status) as Map<String, dynamic>);
    expect(s.state, DaemonState.running);
    expect(s.tunnelInterface, 'utun7');
    expect(s.upstreamDns, ['192.168.1.1', '1.1.1.1']);
    expect(s.route('connected')!.state, RouteState.up);
    expect(s.route('work')!.error, 'dial: timeout');
    expect(s.route('nope'), isNull);
  });

  test('flows', () {
    final f = FlowSnapshot.fromJson(jsonDecode(_flows) as Map<String, dynamic>);
    expect(f.seq, 7);
    expect(f.totalConnections, 12);
    final open = f.active.single;
    expect(open.ended, isNull);
    expect(open.owner, 'Telegram');
    expect(open.target, 't.me');
    final closed = f.closed.single;
    expect(closed.ended, isNotNull);
    expect(closed.owner, 'unknown');
    expect(closed.target, '8.8.8.8:443');
    expect(closed.error, contains('UDP'));
  });

  test('flow statistics parse as vzhukhd writes them', () {
    // Captured from internal/flows Stats, marshalled.
    const raw = r'''{"window":15,"since":"2026-10-20T23:56:20.193525+03:00","rows":[{"app":"Safari","host":"example.com","port":443,"network":"tcp","action":"route","route":"main","ruleId":"r1","appPath":"/Applications/Safari.app","matched":"app \"safari\"","first":"2026-10-20T23:56:20.193525+03:00","last":"2026-10-20T23:56:20.193543+03:00","open":1,"conns":1,"errors":0,"upload":10,"download":0},{"host":"1.2.3.4","port":53,"network":"udp","action":"direct","first":"2026-10-20T23:56:20.193542+03:00","last":"2026-10-20T23:56:20.193543+03:00","open":0,"conns":1,"errors":1,"upload":0,"download":0,"reasons":[{"error":"refused","count":1}]}],"timeline":[{"at":"2026-10-20T23:56:00+03:00","conns":2,"errors":1,"upload":10,"download":0}],"evicted":0}''';
    final stats = FlowStats.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    expect(stats.window, 15);
    final safari = stats.rows.first;
    expect([safari.app, safari.host, safari.port, safari.route, safari.matched, safari.open, safari.upload],
        ['Safari', 'example.com', 443, 'main', 'app "safari"', 1, 10]);
    final dns = stats.rows.last;
    expect([dns.app, dns.owner, dns.network, dns.errors], [null, 'unknown', 'udp', 1]);
    expect(dns.reasons.single, (error: 'refused', count: 1));
    expect(stats.timeline.single.conns, 2);
  });
}
