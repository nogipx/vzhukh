import 'dart:convert';

import '../models/app_set.dart';
import '../models/rule_set.dart';

/// A rule set or an app set as a file of its own: for a backup, or to move
/// it to a device that is not paired.
///
/// The archive carries what the set says and its name, not its id: an
/// imported set is a new set, and importing the same file twice makes two.
class SetArchive {
  const SetArchive._();

  static const _ruleSet = 'ruleset';
  static const _appSet = 'appset';

  static String encodeRuleSet(RuleSet set) => _encode(_ruleSet, set.toJson());
  static String encodeAppSet(AppSet set) => _encode(_appSet, set.toJson());

  static String _encode(String kind, Map<String, dynamic> set) =>
      const JsonEncoder.withIndent('  ').convert({'vzhukh': kind, 'version': 1, 'set': set..remove('id')});

  static String fileName(String setName, String kind) =>
      '${setName.replaceAll(RegExp(r'[^\w\- ]'), '_').trim()}.$kind.json';

  static String ruleSetFile(RuleSet set) => fileName(set.name, _ruleSet);
  static String appSetFile(AppSet set) => fileName(set.name, _appSet);

  /// Reads an archive made by [encodeRuleSet] or [encodeAppSet], giving the
  /// set a fresh [id]. Throws [FormatException] for anything else.
  static Object decode(String text, {required String id}) {
    final Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(text.trim()) as Map);
    } catch (_) {
      throw const FormatException('Not a Vzhukh set');
    }
    final set = json['set'];
    if (set is! Map) throw const FormatException('Not a Vzhukh set');
    final body = {...Map<String, dynamic>.from(set), 'id': id};
    try {
      return switch (json['vzhukh']) {
        _ruleSet => RuleSet.fromJson(body),
        _appSet => AppSet.fromJson(body),
        _ => throw const FormatException('Not a Vzhukh set'),
      };
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('The set is damaged or from a newer Vzhukh');
    }
  }
}
