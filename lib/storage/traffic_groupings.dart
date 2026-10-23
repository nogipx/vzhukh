import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../daemon/traffic_analysis.dart';
import 'plain_store.dart';

/// A named way to group the Traffic table: its levels, outermost first.
@immutable
class TrafficGrouping {
  final String name;
  final List<TrafficDim> chain;

  const TrafficGrouping(this.name, this.chain);

  /// The ones the app comes with.
  static const builtIn = [
    TrafficGrouping('Apps', [TrafficDim.app, TrafficDim.site, TrafficDim.host]),
    TrafficGrouping('Decisions', [TrafficDim.action, TrafficDim.app, TrafficDim.host]),
    TrafficGrouping('Routes', [TrafficDim.route, TrafficDim.app, TrafficDim.site]),
    TrafficGrouping('Sites', [TrafficDim.site, TrafficDim.app]),
    TrafficGrouping('Rules', [TrafficDim.rule, TrafficDim.app, TrafficDim.host]),
  ];

  /// "Action › App › Host".
  String get levels => describe(chain);

  static String describe(List<TrafficDim> chain) => chain.map((d) => d.label).join(' › ');

  bool groupsLike(List<TrafficDim> other) => listEquals(chain, other);

  Map<String, dynamic> toJson() => {'name': name, 'levels': [for (final d in chain) d.key]};

  /// Null for one with no level this version knows.
  static TrafficGrouping? fromJson(Map<String, dynamic> json) {
    final chain = levelsFromJson(json['levels']);
    return chain.isEmpty ? null : TrafficGrouping(json['name'] as String? ?? describe(chain), chain);
  }

  static List<TrafficDim> levelsFromJson(Object? json) => [
        for (final key in json as List? ?? const [])
          if (TrafficDim.byKey('$key') case final d?) d,
      ];
}

/// The groupings saved on this device, and the one last in use, kept
/// between launches.
class TrafficGroupingsRepository {
  const TrafficGroupingsRepository();

  static const _savedKey = 'traffic_groupings';
  static const _currentKey = 'traffic_grouping_current';

  Future<List<TrafficGrouping>> saved() async {
    final raw = await plainStore.read(key: _savedKey);
    if (raw == null) return const [];
    return [
      for (final e in jsonDecode(raw) as List)
        if (TrafficGrouping.fromJson(Map<String, dynamic>.from(e as Map)) case final g?) g,
    ];
  }

  Future<void> save(List<TrafficGrouping> groupings) =>
      plainStore.write(key: _savedKey, value: jsonEncode([for (final g in groupings) g.toJson()]));

  /// The levels last in use, or null before any were chosen.
  Future<List<TrafficDim>?> current() async {
    final raw = await plainStore.read(key: _currentKey);
    if (raw == null) return null;
    final chain = TrafficGrouping.levelsFromJson(jsonDecode(raw));
    return chain.isEmpty ? null : chain;
  }

  Future<void> setCurrent(List<TrafficDim> chain) =>
      plainStore.write(key: _currentKey, value: jsonEncode([for (final d in chain) d.key]));
}
