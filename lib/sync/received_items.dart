import 'package:flutter/foundation.dart';

import '../models/app_set.dart';
import '../models/connection.dart';
import '../models/rule_set.dart';
import '../models/server.dart';
import '../models/tunnel_route.dart';

/// Something a paired device shares with this one, while it is on the
/// network.
@immutable
class Received<T> {
  const Received(this.owner, this.ownerName, this.value);

  /// The owner's key, and what it calls itself.
  final String owner;
  final String ownerName;
  final T value;
}

/// What paired devices share with this one right now, in memory only (see
/// ShareEngine). Lists read it to show the "on this network" sections, and
/// connecting reads it to resolve a received route.
///
/// When a key exists both here and among this device's own things, the own
/// one is used: that is a copy kept earlier.
class ReceivedItems extends ChangeNotifier {
  ReceivedItems();

  static final instance = ReceivedItems();

  var _byOwner = <String, Map<String, Object?>>{};
  var _names = <String, String>{};

  void set(Map<String, Map<String, Object?>> byOwner, Map<String, String> names) {
    _byOwner = byOwner;
    _names = names;
    notifyListeners();
  }

  bool get isEmpty => _byOwner.values.every((v) => v.isEmpty);

  String? ownerOf(String key) {
    for (final MapEntry(key: owner, value: values) in _byOwner.entries) {
      if (values.containsKey(key)) return owner;
    }
    return null;
  }

  String? ownerNameOf(String key) {
    final owner = ownerOf(key);
    return owner == null ? null : _names[owner] ?? 'another device';
  }

  List<Received<T>> _all<T>(String prefix, T Function(Map<String, dynamic>) decode) => [
        for (final MapEntry(key: owner, value: values) in _byOwner.entries)
          for (final MapEntry(:key, :value) in values.entries)
            if (key.startsWith(prefix) && value is Map)
              if (_decode(decode, value) case final T v)
                Received(owner, _names[owner] ?? 'another device', v),
      ];

  static T? _decode<T>(T Function(Map<String, dynamic>) decode, Map value) {
    try {
      return decode(Map<String, dynamic>.from(value));
    } catch (_) {
      return null;
    }
  }

  T? _one<T>(String key, T Function(Map<String, dynamic>) decode) {
    final owner = ownerOf(key);
    final value = owner == null ? null : _byOwner[owner]![key];
    return value is Map ? _decode(decode, value) : null;
  }

  List<Received<Server>> get servers => _all('server/', Server.fromJson);
  List<Received<TunnelRoute>> get routes => _all('route/', TunnelRoute.fromJson);
  List<Received<RuleSet>> get ruleSets => _all('ruleset/', RuleSet.fromJson);
  List<Received<AppSet>> get appSets => _all('appset/', AppSet.fromJson);

  Server? server(String id) => _one('server/$id', Server.fromJson);
  TunnelRoute? route(String id) => _one('route/$id', TunnelRoute.fromJson);
  RuleSet? ruleSet(String id) => _one('ruleset/$id', RuleSet.fromJson);
  AppSet? appSet(String id) => _one('appset/$id', AppSet.fromJson);

  /// The app set a received server points at, if any.
  String? serverAppSet(String serverId) {
    final link = ownerOf('serverapps/$serverId');
    final value = link == null ? null : _byOwner[link]!['serverapps/$serverId'];
    return value is Map ? value['appSetId'] as String? : null;
  }

  List<Connection> connections(String serverId) => [
        for (final r in _all('conn/$serverId/', Connection.fromJson)) r.value,
      ];
}
