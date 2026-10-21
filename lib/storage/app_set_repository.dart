import 'dart:convert';

import '../models/app_routing_config.dart';
import '../models/app_set.dart';
import '../sync/received_items.dart';
import '../sync/sync_signal.dart';
import 'plain_store.dart';

/// The Android app sets, and which set each server uses.
class AppSetRepository {
  AppSetRepository({ReceivedItems? received})
      : _received = received ?? ReceivedItems.instance;

  final ReceivedItems _received;

  static const key = 'app_sets';
  static const serverLinkPrefix = 'server_app_set_';

  static String newId() => 'appset_${DateTime.now().microsecondsSinceEpoch}';

  Future<List<AppSet>> getAll() async {
    final raw = await plainStore.read(key: key);
    if (raw == null) return [];
    return [
      for (final e in jsonDecode(raw) as List) AppSet.fromJson(Map<String, dynamic>.from(e as Map)),
    ];
  }

  Future<void> _write(List<AppSet> sets) =>
      plainStore.write(key: key, value: jsonEncode(sets.map((s) => s.toJson()).toList()));

  Future<void> save(AppSet set) async {
    final sets = await getAll();
    final i = sets.indexWhere((s) => s.id == set.id);
    i >= 0 ? sets[i] = set : sets.add(set);
    await _write(sets);
    SyncSignal.instance.localChanged();
  }

  Future<void> delete(String id) async {
    await _write((await getAll())..removeWhere((s) => s.id == id));
    SyncSignal.instance.localChanged();
  }

  /// [id] from this device's own sets, else from a received one.
  Future<AppSet?> find(String? id) async {
    if (id == null) return null;
    return (await getAll()).where((s) => s.id == id).firstOrNull ?? _received.appSet(id);
  }

  /// What [id] says about apps, or null for all apps.
  Future<AppRoutingConfig?> configOf(String? id) async {
    final config = (await find(id))?.config;
    return config == null || config.packages.isEmpty ? null : config;
  }

  static const localChoicePrefix = 'local_app_set_';

  /// The app set this device picked for [item] ('server/ID' or 'route/ID'),
  /// over what the server or route says itself. Device-local and never
  /// synced: a TV picks for things it was only shared. '' is all apps, null
  /// is no choice made here.
  Future<String?> localChoice(String item) => plainStore.read(key: '$localChoicePrefix$item');

  /// [setId] null picks all apps.
  Future<void> setLocalChoice(String item, String? setId) async {
    await plainStore.write(key: '$localChoicePrefix$item', value: setId ?? '');
    SyncSignal.instance.localChanged();
  }

  Future<String?> serverSet(String serverId) async =>
      await plainStore.read(key: '$serverLinkPrefix$serverId') ?? _received.serverAppSet(serverId);

  Future<void> setServerSet(String serverId, String? setId) async {
    setId == null
        ? await plainStore.delete(key: '$serverLinkPrefix$serverId')
        : await plainStore.write(key: '$serverLinkPrefix$serverId', value: setId);
    SyncSignal.instance.localChanged();
  }
}
