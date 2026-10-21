import 'routing_rule.dart';

/// A named set of macOS routing rules. One set is active on a Mac at a time;
/// sets can be switched, shared and exported on their own.
class RuleSet {
  final String id;
  final String name;
  final RoutingRules rules;

  const RuleSet({required this.id, required this.name, required this.rules});

  RuleSet copyWith({String? name, RoutingRules? rules}) =>
      RuleSet(id: id, name: name ?? this.name, rules: rules ?? this.rules);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'rules': rules.toJson()};

  factory RuleSet.fromJson(Map<String, dynamic> json) => RuleSet(
        id: json['id'] as String,
        name: json['name'] as String,
        rules: RoutingRules.fromJson(Map<String, dynamic>.from(json['rules'] as Map)),
      );
}
