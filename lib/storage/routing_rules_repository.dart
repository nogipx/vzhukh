import '../models/routing_rule.dart';
import '../models/rule_set.dart';
import '../sync/received_items.dart';
import 'route_repository.dart';
import 'rule_set_repository.dart';

/// The rules in force on this Mac: those of the active rule set. What the
/// daemon config and the Traffic tab read.
class RoutingRulesRepository {
  RoutingRulesRepository({RuleSetRepository? sets}) : _sets = sets ?? RuleSetRepository();

  final RuleSetRepository _sets;

  Future<RoutingRules> load() async => (await _sets.active()).set?.rules ?? const RoutingRules();

  /// The rules as the tunnel should get them. A rule naming a route this
  /// device does not have, as one in a set from another device may, sends
  /// its traffic through the connected route instead.
  Future<RoutingRules> effective() async {
    final rules = await load();
    final known = {
      for (final r in await RouteRepository().getRoutes()) r.id,
      for (final r in ReceivedItems.instance.routes) r.value.id,
    };
    return rules.copyWith(rules: [
      for (final r in rules.rules)
        r.action == RuleAction.route && !known.contains(r.routeId)
            ? r.copyWith(action: RuleAction.connectedRoute, clearRouteId: true)
            : r,
    ]);
  }

  /// Saves into the active set when it is this device's own; with no set at
  /// all, makes the first.
  Future<void> save(RoutingRules rules) async {
    final active = await _sets.active();
    final set = active.set;
    if (set == null) {
      final first = await _createFirst(rules);
      await _sets.setActive(first);
      return;
    }
    if (!active.own) throw StateError('The active rules belong to another device');
    await _sets.save(set.copyWith(rules: rules));
  }

  Future<String> _createFirst(RoutingRules rules) async {
    final id = RuleSetRepository.newId();
    await _sets.save(RuleSet(id: id, name: 'My rules', rules: rules));
    return id;
  }
}
