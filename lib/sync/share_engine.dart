import 'dart:async';
import 'dart:convert';

/// This device's own shareable things: every one under a key of its own, as
/// JSON.
abstract class SyncedData {
  /// Everything there is now. A key that is absent does not exist.
  Future<Map<String, Object?>> snapshot();

  /// Stores [values] (null deletes the key). The order is the order to
  /// apply them in.
  Future<void> apply(List<MapEntry<String, Object?>> values);

  /// The keys that go along when [item] is shared: a server takes its
  /// connections and app set, a route the servers and connections of its
  /// hops and its app set.
  Set<String> closure(Map<String, Object?> snapshot, String item);
}

/// Where the engine keeps its state between runs.
abstract class LedgerStore {
  Future<String?> read();
  Future<void> write(String raw);
}

/// Shares what this device owns with the paired devices its owner chose,
/// and holds what others share with it.
///
/// Every exchange carries an offer: all of the sender's own items shared
/// with the receiver, whole. What is received is kept in memory only, apart
/// from this device's own things, and replaced by each offer: an item the
/// owner stops sharing is gone with the next one, and everything from an
/// owner is gone when it leaves the network ([suspend]). Nothing received
/// reaches this device's storage unless its owner allows a copy ([adopt]),
/// or this device is given [retained]: then the last offer of each owner
/// stays, across runs and while the owner is away.
///
/// The owner is the source of truth: a received item cannot be edited here,
/// and is never offered onward.
class ShareEngine {
  ShareEngine({required this.data, required this.store, this.retained});

  final SyncedData data;
  final LedgerStore store;

  /// Where what others share is kept between runs, on a device that has to
  /// work without its owner's phone nearby: a TV, which cannot set anything
  /// up by itself. The offers carry private keys, so this is the keychain.
  /// Null keeps what is received in memory only.
  final LedgerStore? retained;

  /// Own item -> the peers it is shared with.
  var _shares = <String, Set<String>>{};

  /// Owner -> what it shares with this device now. Memory only.
  final _received = <String, Map<String, Object?>>{};

  /// Peer -> the copies it was allowed, ready to go with the next exchange,
  /// and the items it was refused. Memory only: a copy carries a private
  /// key, which has no business on disk here.
  final _grants = <String, Map<String, List<Map<String, dynamic>>>>{};
  final _denials = <String, Set<String>>{};

  /// Keys an earlier version wrote into this device's storage from other
  /// devices. Removed once by [load].
  Set<String> _leftovers = {};

  bool _loaded = false;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Reads the state, and removes from storage what an earlier version put
  /// there from other devices. Returns the keys it removed.
  Future<Set<String>> load() => _serial(() async {
        await _load();
        final leftovers = _leftovers;
        _leftovers = {};
        if (leftovers.isEmpty) return <String>{};
        final snapshot = await data.snapshot();
        final present = leftovers.where(snapshot.containsKey).toSet();
        if (present.isNotEmpty) {
          await data.apply([for (final k in present) MapEntry(k, null)]);
        }
        await _save();
        return present;
      });

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final kept = await retained?.read();
    if (kept != null && kept.isNotEmpty) {
      for (final MapEntry(:key, :value) in (jsonDecode(kept) as Map).entries) {
        _received[key as String] = Map<String, Object?>.from(value as Map);
      }
    }
    final raw = await store.read();
    if (raw == null || raw.isEmpty) return;
    final j = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    Map<String, Set<String>> sets(Object? o) => {
          for (final MapEntry(:key, :value) in (o as Map? ?? {}).entries)
            key as String: {...(value as List).cast<String>()},
        };
    _shares = sets(j['shares']);
    // The previous version stored received items as if they were own.
    for (final keys in (j['received'] as Map? ?? {}).values) {
      _leftovers.addAll((keys as Map).keys.cast<String>());
    }
  }

  Future<void> _save() => store.write(jsonEncode({
        'shares': _shares.map((k, v) => MapEntry(k, v.toList())),
      }));

  Future<void> _saveRetained() async {
    await retained?.write(jsonEncode(_received));
  }

  /// Everything received, by owner.
  Map<String, Map<String, Object?>> get received =>
      {for (final MapEntry(:key, :value) in _received.entries) key: Map.unmodifiable(value)};

  /// The device [key] was received from, or null.
  String? ownerOf(String key) {
    for (final MapEntry(key: owner, value: values) in _received.entries) {
      if (values.containsKey(key)) return owner;
    }
    return null;
  }

  Set<String> sharesOf(String item) => {...?_shares[item]};

  Future<void> setShares(String item, Set<String> peers) => _serial(() async {
        await _load();
        peers.isEmpty ? _shares.remove(item) : _shares[item] = {...peers};
        await _save();
      });

  /// Everything of this device's own shared with [peer], as it is now.
  Future<List<Map<String, dynamic>>> offerFor(String peer) => _serial(() async {
        await _load();
        final snapshot = await data.snapshot();
        final keys = <String>{};
        for (final MapEntry(key: item, value: peers) in _shares.entries) {
          if (peers.contains(peer) && snapshot.containsKey(item)) {
            keys.addAll(data.closure(snapshot, item));
          }
        }
        return [
          for (final k in keys)
            if (snapshot.containsKey(k)) {'k': k, 'v': snapshot[k]},
        ];
      });

  /// Takes [offer] as everything [owner] shares with this device now.
  /// Returns whether that changed anything.
  bool accept(String owner, List<Map<String, dynamic>> offer) {
    final next = {for (final e in offer) e['k'] as String: e['v']};
    final before = _received[owner] ?? const {};
    next.isEmpty ? _received.remove(owner) : _received[owner] = next;
    final changed = jsonEncode(before) != jsonEncode(next);
    if (changed && retained != null) _serial(_saveRetained);
    return changed;
  }

  /// Forgets what [owner] shares, while it cannot be reached. Its next offer
  /// brings it all back. Returns whether there was anything. Nothing is
  /// forgotten when received items are [retained].
  bool suspend(String owner) =>
      retained == null && (_received.remove(owner)?.isNotEmpty ?? false);

  /// Stores a copy [peer] allowed this device to keep (BuildCopyBundle) as
  /// its own. Returns the keys written.
  Future<Set<String>> keep(List<Map<String, dynamic>> bundle) => _serial(() async {
        final values = {for (final e in bundle) e['k'] as String: e['v']};
        await data.apply([for (final e in values.entries) MapEntry(e.key, e.value)]);
        return values.keys.toSet();
      });

  /// Answers [peer]'s request to keep a copy of the own [item]: [bundle] is
  /// the copy, null refuses.
  void answer(String peer, String item, List<Map<String, dynamic>>? bundle) {
    if (bundle == null) {
      _denials.putIfAbsent(peer, () => {}).add(item);
    } else {
      _grants.putIfAbsent(peer, () => {})[item] = bundle;
    }
  }

  /// The answers waiting to go to [peer].
  ({Map<String, List<Map<String, dynamic>>> grants, Set<String> denials}) answersFor(String peer) =>
      (grants: {...?_grants[peer]}, denials: {...?_denials[peer]});

  /// Forgets answers [peer] has received.
  void delivered(String peer, Iterable<String> grants, Iterable<String> denials) {
    _grants[peer]?.removeWhere((k, _) => grants.contains(k));
    _denials[peer]?.removeAll(denials);
    _grants.removeWhere((_, v) => v.isEmpty);
    _denials.removeWhere((_, v) => v.isEmpty);
  }

  /// Stops sharing with [peer] and drops what it shared here.
  Future<void> forgetPeer(String peer) => _serial(() async {
        await _load();
        for (final peers in _shares.values) {
          peers.remove(peer);
        }
        _shares.removeWhere((_, peers) => peers.isEmpty);
        _grants.remove(peer);
        _denials.remove(peer);
        _received.remove(peer);
        await _save();
        await _saveRetained();
      });

  /// Deletes what the first version, which synced everything both ways,
  /// brought in from other devices: keys whose last writer in its ledger
  /// was not [me].
  Future<Set<String>> dropSyncedFromOthers(String ledgerRaw, String me) =>
      _serial(() async {
        final entries = (jsonDecode(ledgerRaw) as Map)['entries'] as Map? ?? {};
        final snapshot = await data.snapshot();
        final foreign = <String>{
          for (final MapEntry(:key, :value) in entries.entries)
            if ((value as Map)['by'] != me && value['d'] != true && snapshot.containsKey(key))
              key as String,
        };
        if (foreign.isNotEmpty) {
          await data.apply([for (final k in foreign) MapEntry(k, null)]);
        }
        return foreign;
      });
}
