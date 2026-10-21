import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/models/app_routing_config.dart';
import 'package:vzhukh/models/app_set.dart';
import 'package:vzhukh/models/routing_rule.dart';
import 'package:vzhukh/models/rule_set.dart';
import 'package:vzhukh/storage/set_archive.dart';
import 'package:vzhukh/sync/repository_synced_data.dart';

void main() {
  group('archive', () {
    const rules = RuleSet(
      id: 'old',
      name: 'Work',
      rules: RoutingRules(defaultAction: DefaultAction.direct),
    );
    const apps = AppSet(
      id: 'old',
      name: 'Browsers',
      config: AppRoutingConfig(mode: AppRoutingMode.whitelist, packages: ['org.mozilla.firefox']),
    );

    test('a set comes back under a new id, the rest as it was', () {
      final r = SetArchive.decode(SetArchive.encodeRuleSet(rules), id: 'new') as RuleSet;
      expect(r.id, 'new');
      expect(r.name, 'Work');
      expect(r.rules.defaultAction, DefaultAction.direct);

      final a = SetArchive.decode(SetArchive.encodeAppSet(apps), id: 'new') as AppSet;
      expect(a.id, 'new');
      expect(a.config.packages, ['org.mozilla.firefox']);
      expect(a.config.mode, AppRoutingMode.whitelist);
    });

    test('anything else is refused', () {
      expect(() => SetArchive.decode('hello', id: 'x'), throwsFormatException);
      expect(() => SetArchive.decode('{"vzhukh":"route","set":{}}', id: 'x'), throwsFormatException);
      expect(() => SetArchive.decode('{"vzhukh":"ruleset","set":{"name":1}}', id: 'x'),
          throwsFormatException);
    });

    test('file names are safe', () {
      expect(SetArchive.ruleSetFile(rules.copyWith(name: 'a/b: c')), 'a_b_ c.ruleset.json');
    });
  });

  group('what goes along when sharing', () {
    final data = RepositorySyncedData();
    final snapshot = <String, Object?>{
      'server/s1': {},
      'conn/s1/c1': {},
      'conn/s1/c2': {},
      'serverapps/s1': {'appSetId': 'a1'},
      'appset/a1': {},
      'server/s2': {},
      'conn/s2/c3': {},
      'route/r1': {
        'hops': [
          {'serverId': 's2', 'connectionId': 'c3'},
        ],
        'appSetId': 'a2',
      },
    };

    test('a server takes its connections and app set', () {
      expect(data.closure(snapshot, 'server/s1'),
          {'server/s1', 'conn/s1/c1', 'conn/s1/c2', 'serverapps/s1', 'appset/a1'});
    });

    test('a route takes its hops, only the connection it uses, and its app set', () {
      expect(data.closure(snapshot, 'route/r1'),
          {'route/r1', 'server/s2', 'conn/s2/c3', 'appset/a2'});
    });

    test('a set goes alone', () {
      expect(data.closure(snapshot, 'ruleset/x'), {'ruleset/x'});
    });
  });
}
