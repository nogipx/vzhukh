import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/daemon/build_daemon_config.dart';
import 'package:vzhukh/models/routing_rule.dart';
import 'package:vzhukh/models/rule_folders.dart';

RoutingRule _r(String id, [String? folder]) => RoutingRule(id: id, name: id, action: RuleAction.direct, folderId: folder);

List<String> _ids(RoutingRules rules) => [for (final r in rules.rules) '${r.id}${r.folderId == null ? '' : '@${r.folderId}'}'];

void main() {
  const work = RuleFolder(id: 'work', name: 'Work');

  test('a folder gathers its rules where its first one stands and goes when empty', () {
    final rules = RoutingRules(
      rules: [_r('a'), _r('b', 'work'), _r('c'), _r('d', 'work'), _r('e', 'gone')],
      folders: const [work, RuleFolder(id: 'empty', name: 'Empty')],
    ).normalized();
    expect(_ids(rules), ['a', 'b@work', 'd@work', 'c', 'e']);
    expect(rules.folders.map((f) => f.id), ['work']);
  });

  test('rules move into a folder, out of it, and a folder moves whole', () {
    var rules = RoutingRules(rules: [_r('a'), _r('b'), _r('c'), _r('d')]).newFolder('b', work);
    rules = rules.moveToFolder('d', 'work');
    expect(_ids(rules), ['a', 'b@work', 'd@work', 'c']);

    rules = rules.takeOutOfFolder('b');
    expect(_ids(rules), ['a', 'd@work', 'b', 'c']);

    rules = rules.moveFolder('work', toTop: false);
    expect(_ids(rules), ['a', 'b', 'c', 'd@work']);

    expect(_ids(rules.ungroup('work')), ['a', 'b', 'c', 'd']);
    expect(_ids(rules.deleteFolder('work')), ['a', 'b', 'c']);
  });

  test('a dragged rule joins the folder it lands after', () {
    // a, [work], b@work, c@work, d
    final rules = RoutingRules(rules: [_r('a'), _r('b', 'work'), _r('c', 'work'), _r('d')], folders: const [work]);
    expect(rules.entries().length, 5);

    // d (4) to just after the heading (index 2 once taken out).
    expect(_ids(rules.reorder(4, 2)), ['a', 'd@work', 'b@work', 'c@work']);
    // b (2) out to the very top.
    expect(_ids(rules.reorder(2, 0)), ['b', 'a', 'c@work', 'd']);
    // a (0) to after d: on its own.
    expect(_ids(rules.reorder(0, 4)), ['b@work', 'c@work', 'd', 'a']);
  });

  test('a dragged folder takes its rules along, open or collapsed', () {
    final open = RoutingRules(rules: [_r('a'), _r('b', 'work'), _r('c', 'work'), _r('d')], folders: const [work]);
    // The heading (1) to the end: 4 once it is taken out.
    expect(_ids(open.reorder(1, 4)), ['a', 'd', 'b@work', 'c@work']);
    // Dropped among its own rules, nothing moves.
    expect(_ids(open.reorder(1, 2)), _ids(open));

    final shut = open.updateFolder(work.copyWith(collapsed: true));
    expect(shut.entries().length, 3);
    expect(_ids(shut.reorder(1, 0)), ['b@work', 'c@work', 'a', 'd']);
  });

  test('a folder that is off takes its rules out of play, their own switches kept', () {
    final rules = RoutingRules(
      rules: [_r('a', 'work'), _r('b')],
      folders: [work.copyWith(enabled: false)],
    );
    final section = BuildDaemonConfig.rulesSection(rules);
    expect([for (final r in section['rules'] as List) r['disabled']], [true, false]);
    expect(rules.rules.first.enabled, isTrue);
  });

  test('folders survive a round trip', () {
    final rules = RoutingRules(rules: [_r('a', 'work')], folders: [work.copyWith(collapsed: true)]);
    final back = RoutingRules.fromJson(rules.toJson());
    expect(back.folders.single.collapsed, isTrue);
    expect(back.rules.single.folderId, 'work');
    expect(const RoutingRules().toJson().containsKey('folders'), isFalse);
  });
}
