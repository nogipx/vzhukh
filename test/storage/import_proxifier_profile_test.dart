import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/models/routing_rule.dart';
import 'package:vzhukh/storage/import_proxifier_profile.dart';

const _profile = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxifierProfile version="101" platform="MacOSX" product_id="2" product_minver="200">
    <ProxyList>
        <Proxy id="100" type="SOCKS5"><Address>127.0.0.1</Address><Port>2080</Port></Proxy>
    </ProxyList>
    <RuleList>
        <Rule enabled="true">
            <Name>Telegram</Name>
            <Applications>"Telegram.app"; "Telegram"; ru.keepcoder.Telegram</Applications>
            <Action type="Direct"/>
        </Rule>
        <Rule enabled="true">
            <Name>bundle only</Name>
            <Applications>dev.nogipx.vzhukh</Applications>
            <Action type="Direct"/>
        </Rule>
        <Rule enabled="false">
            <Name>yt</Name>
            <Targets>youtube.com; *.youtube.com; 	*.ytimg.com; %SimpleHostnames%; *google*</Targets>
            <Ports>443; 8000 - 8999</Ports>
            <Action type="Proxy">100</Action>
        </Rule>
        <Rule enabled="true">
            <Name>lan</Name>
            <Targets>10.0.0.0/8; 192.168.*.*; 172.16.0.1-172.16.0.6; 127.0.0.1</Targets>
            <Action type="Block"/>
        </Rule>
        <Rule enabled="true">
            <Name>Default</Name>
            <Action type="Direct"/>
        </Rule>
    </RuleList>
</ProxifierProfile>
''';

void main() {
  const import = ImportProxifierProfile();

  test('one profile is one set, rules in order, Default as the default', () {
    final result = import(_profile, id: 'set', name: 'From home');
    final set = result.set;
    expect(set.id, 'set');
    expect(set.name, 'From home');
    expect(set.rules.defaultAction, DefaultAction.direct);
    expect(set.rules.rules.map((r) => r.name), ['Telegram', 'yt', 'lan']);

    final [telegram, yt, lan] = set.rules.rules;
    expect(telegram.apps, ['Telegram']);
    expect(telegram.action, RuleAction.direct);

    expect(yt.enabled, isFalse);
    expect(yt.action, RuleAction.connectedRoute);
    expect(yt.domains, ['youtube.com', 'ytimg.com']);
    expect(yt.ports, ['443', '8000-8999']);

    expect(lan.action, RuleAction.block);
    expect(lan.cidrs, [
      '10.0.0.0/8',
      '192.168.0.0/16',
      '172.16.0.1/32',
      '172.16.0.2/31',
      '172.16.0.4/31',
      '172.16.0.6/32',
      '127.0.0.1',
    ]);
  });

  test('what cannot be matched is reported, and never widens a rule', () {
    final skipped = import(_profile, id: 'set', name: 'x').skipped;
    expect(skipped, isNot(contains(contains('ru.keepcoder.Telegram'))));
    expect(skipped, contains(contains('dev.nogipx.vzhukh')));
    expect(skipped, contains(contains('%SimpleHostnames%')));
    expect(skipped, contains(contains('*google*')));
    expect(skipped, contains('bundle only: the whole rule, nothing left to match on'));
  });

  test('a Default through a proxy is the connected route', () {
    final text = _profile.replaceFirst(
      '<Name>Default</Name>\n            <Action type="Direct"/>',
      '<Name>Default</Name>\n            <Action type="Proxy">100</Action>',
    );
    expect(import(text, id: 's', name: 'x').set.rules.defaultAction, DefaultAction.connectedRoute);
  });

  test('anything else is refused', () {
    expect(() => import('{"vzhukh":"ruleset"}', id: 's', name: 'x'), throwsFormatException);
    expect(() => import('<foo/>', id: 's', name: 'x'), throwsFormatException);
  });
}
