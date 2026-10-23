import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/daemon/traffic_analysis.dart';
import 'package:vzhukh/storage/traffic_groupings.dart';

void main() {
  test('a grouping survives a round trip, levels in order', () {
    const g = TrafficGrouping('Decisions', [TrafficDim.action, TrafficDim.app, TrafficDim.host]);
    final back = TrafficGrouping.fromJson(g.toJson())!;
    expect(back.name, 'Decisions');
    expect(back.chain, g.chain);
    expect(back.levels, 'Action › App › Host');
    expect(back.groupsLike([TrafficDim.action, TrafficDim.app, TrafficDim.host]), isTrue);
    expect(back.groupsLike([TrafficDim.app, TrafficDim.action, TrafficDim.host]), isFalse);
  });

  test('levels a newer version wrote are skipped, and nothing known is no grouping', () {
    expect(TrafficGrouping.levelsFromJson(['app', 'colour', 'host']), [TrafficDim.app, TrafficDim.host]);
    expect(TrafficGrouping.fromJson({'name': 'x', 'levels': ['colour']}), isNull);
  });

  test('the built-in groupings are distinct', () {
    final seen = <String>{};
    for (final g in TrafficGrouping.builtIn) {
      expect(seen.add(g.levels), isTrue, reason: g.name);
    }
  });
}
