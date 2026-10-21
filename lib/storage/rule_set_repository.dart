import 'dart:convert';

import '../models/routing_rule.dart';
import '../models/rule_set.dart';
import '../sync/received_items.dart';
import '../sync/sync_signal.dart';
import 'plain_store.dart';

/// The Mac's rule sets, and which one is active.
///
/// The active set is this device's choice and is not shared. It may be a set
/// another device shares, for as long as that device is on the network;
/// when it is not, the own set active before it applies again.
class RuleSetRepository {
  RuleSetRepository({ReceivedItems? received})
      : _received = received ?? ReceivedItems.instance;

  final ReceivedItems _received;

  static const key = 'rule_sets';
  static const _activeKey = 'rule_set_active';
  static const _fallbackKey = 'rule_set_fallback';

  /// Where the rules lived before there were sets.
  static const _legacyKey = 'routing_rules';

  Future<List<RuleSet>> getAll() async {
    final raw = await plainStore.read(key: key);
    if (raw != null) {
      return [
        for (final e in jsonDecode(raw) as List)
          RuleSet.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
    }
    final legacy = await plainStore.read(key: _legacyKey);
    if (legacy == null) return [];
    final set = RuleSet(
      id: newId(),
      name: 'My rules',
      rules: RoutingRules.fromJson(Map<String, dynamic>.from(jsonDecode(legacy) as Map)),
    );
    await _write([set]);
    await plainStore.write(key: _activeKey, value: set.id);
    // The old rules stay where they were, for a build from before sets.
    return [set];
  }

  static String newId() => 'ruleset_${DateTime.now().microsecondsSinceEpoch}';

  Future<void> _write(List<RuleSet> sets) =>
      plainStore.write(key: key, value: jsonEncode(sets.map((s) => s.toJson()).toList()));

  Future<void> save(RuleSet set) async {
    final sets = await getAll();
    final i = sets.indexWhere((s) => s.id == set.id);
    i >= 0 ? sets[i] = set : sets.add(set);
    await _write(sets);
    SyncSignal.instance.localChanged();
  }

  Future<void> delete(String id) async {
    final sets = await getAll()
      ..removeWhere((s) => s.id == id);
    await _write(sets);
    if (await plainStore.read(key: _activeKey) == id) {
      await setActive(sets.firstOrNull?.id);
    }
    SyncSignal.instance.localChanged();
  }

  /// The id the user chose, whether or not it is available now.
  Future<String?> chosenId() => plainStore.read(key: _activeKey);

  /// Makes [id] active. Choosing a received set remembers the own set that
  /// was active, to go back to when the received one goes away.
  Future<void> setActive(String? id) async {
    if (id == null) {
      await plainStore.delete(key: _activeKey);
      return;
    }
    final own = await getAll();
    final current = await plainStore.read(key: _activeKey);
    if (own.any((s) => s.id == id)) {
      await plainStore.delete(key: _fallbackKey);
    } else if (own.any((s) => s.id == current)) {
      await plainStore.write(key: _fallbackKey, value: current!);
    }
    await plainStore.write(key: _activeKey, value: id);
  }

  /// The set in force now, and whether it is this device's own.
  Future<({RuleSet? set, bool own})> active() async {
    final own = await getAll();
    final chosen = await plainStore.read(key: _activeKey);
    final mine = own.where((s) => s.id == chosen).firstOrNull;
    if (mine != null) return (set: mine, own: true);
    if (chosen != null) {
      final received = _received.ruleSet(chosen);
      if (received != null) return (set: received, own: false);
    }
    final fallback = await plainStore.read(key: _fallbackKey);
    final back = own.where((s) => s.id == fallback).firstOrNull ?? own.firstOrNull;
    return (set: back, own: back != null);
  }
}
