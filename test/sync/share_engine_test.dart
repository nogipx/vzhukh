import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/sync/share_engine.dart';

/// Keys as the app has them; a route names its server in 'server'.
class FakeData implements SyncedData {
  final values = <String, Object?>{};

  @override
  Future<Map<String, Object?>> snapshot() async => Map.of(values);

  @override
  Future<void> apply(List<MapEntry<String, Object?>> batch) async {
    for (final e in batch) {
      if (e.value == null) {
        values.remove(e.key);
      } else {
        values[e.key] = Map<String, Object?>.from(e.value as Map);
      }
    }
  }

  @override
  Set<String> closure(Map<String, Object?> snapshot, String item) => {
        item,
        if (item.startsWith('server/'))
          ...snapshot.keys.where((k) => k.startsWith('conn/${item.substring(7)}/')),
        if ((snapshot[item] as Map?)?['server'] case final String s) ...{
          'server/$s',
          ...snapshot.keys.where((k) => k.startsWith('conn/$s/')),
        },
      };
}

class MemStore implements LedgerStore {
  String? raw;
  @override
  Future<String?> read() async => raw;
  @override
  Future<void> write(String raw) async => this.raw = raw;
}

class _Device {
  _Device(this.id) {
    engine = ShareEngine(data: data, store: store);
  }
  final String id;
  final data = FakeData();
  final store = MemStore();
  late final ShareEngine engine;

  /// One exchange as LanSync does it: each side sends its offer for the other.
  Future<void> exchange(_Device other) async {
    other.engine.accept(id, await engine.offerFor(other.id));
    engine.accept(other.id, await other.engine.offerFor(id));
  }
}

void main() {
  late _Device mac, phone, tv;

  setUp(() {
    mac = _Device('mac');
    phone = _Device('phone');
    tv = _Device('tv');
    mac.data.values.addAll({
      'server/s1': {'host': 'a'},
      'conn/s1/c1': {'key': 'PRIVATE'},
      'server/s2': {'host': 'b'},
      'route/r1': {'label': 'home', 'server': 's1'},
      'ruleset/w': {'name': 'Work'},
    });
  });

  Map<String, Object?>? from(_Device d, String owner) => d.engine.received[owner];

  test('nothing is shared until the owner shares it', () async {
    await mac.exchange(phone);
    expect(phone.engine.received, isEmpty);
  });

  test('a shared server arrives with its connections, in memory, only on the chosen device', () async {
    await mac.engine.setShares('server/s1', {'phone'});
    await mac.exchange(phone);
    await mac.exchange(tv);
    expect(from(phone, 'mac')!.keys, unorderedEquals(['server/s1', 'conn/s1/c1']));
    expect(phone.data.values, isEmpty, reason: 'nothing received is stored');
    expect(tv.engine.received, isEmpty);
    expect(phone.engine.ownerOf('server/s1'), 'mac');
  });

  test('a shared route brings the server it goes through', () async {
    await mac.engine.setShares('route/r1', {'phone'});
    await mac.exchange(phone);
    expect(from(phone, 'mac')!.keys, unorderedEquals(['route/r1', 'server/s1', 'conn/s1/c1']));
  });

  test("the owner's edits arrive, unsharing takes it away", () async {
    await mac.engine.setShares('server/s2', {'phone'});
    await mac.exchange(phone);
    mac.data.values['server/s2'] = {'host': 'changed'};
    await mac.exchange(phone);
    expect(from(phone, 'mac')!['server/s2'], {'host': 'changed'});
    await mac.engine.setShares('server/s2', {});
    await mac.exchange(phone);
    expect(phone.engine.received, isEmpty);
  });

  test('a received item is never offered onward', () async {
    await mac.engine.setShares('server/s1', {'phone'});
    await mac.exchange(phone);
    await phone.engine.setShares('server/s1', {'tv'});
    await phone.exchange(tv);
    expect(tv.engine.received, isEmpty);
  });

  test('suspended while the owner is away, back with its next offer', () async {
    await mac.engine.setShares('route/r1', {'phone'});
    await mac.exchange(phone);
    expect(phone.engine.suspend('mac'), isTrue);
    expect(phone.engine.received, isEmpty);
    await mac.exchange(phone);
    expect(from(phone, 'mac'), hasLength(3));
  });

  test('a TV keeps what it was shared while the owner is away and after a restart', () async {
    final kept = MemStore();
    final tvEngine = ShareEngine(data: tv.data, store: tv.store, retained: kept);
    await mac.engine.setShares('route/r1', {'tv'});
    tvEngine.accept('mac', await mac.engine.offerFor('tv'));
    expect(tvEngine.suspend('mac'), isFalse);
    expect(tvEngine.received['mac'], hasLength(3));
    expect(tv.data.values, isEmpty, reason: 'kept apart from its own');

    await tvEngine.load();
    final restarted = ShareEngine(data: tv.data, store: tv.store, retained: kept);
    await restarted.load();
    expect(restarted.received['mac']!.keys, unorderedEquals(['route/r1', 'server/s1', 'conn/s1/c1']));

    await mac.engine.setShares('route/r1', {});
    restarted.accept('mac', await mac.engine.offerFor('tv'));
    await restarted.load();
    final again = ShareEngine(data: tv.data, store: tv.store, retained: kept);
    await again.load();
    expect(again.received, isEmpty, reason: 'unsharing reaches the kept copy too');
  });

  test('a kept copy is stored as the receiver\'s own', () async {
    final keys = await phone.engine.keep([
      {'k': 'server/s1', 'v': {'host': 'a'}},
      {'k': 'conn/s1/new', 'v': {'key': 'NEW'}},
    ]);
    expect(keys, {'server/s1', 'conn/s1/new'});
    expect(phone.data.values.keys, unorderedEquals(['server/s1', 'conn/s1/new']));
  });

  test('forgetting a peer drops what it shared and what was shared with it', () async {
    await mac.engine.setShares('server/s1', {'phone'});
    await mac.exchange(phone);
    await phone.engine.forgetPeer('mac');
    expect(phone.engine.received, isEmpty);
    await mac.engine.forgetPeer('phone');
    expect(mac.engine.sharesOf('server/s1'), isEmpty);
  });

  test('answers wait for the peer until delivered', () async {
    mac.engine.answer('phone', 'server/s1', [
      {'k': 'server/s1', 'v': {}},
    ]);
    mac.engine.answer('phone', 'route/r1', null);
    final a = mac.engine.answersFor('phone');
    expect(a.grants.keys, ['server/s1']);
    expect(a.denials, {'route/r1'});
    mac.engine.delivered('phone', a.grants.keys, a.denials);
    expect(mac.engine.answersFor('phone').grants, isEmpty);
    expect(mac.engine.answersFor('phone').denials, isEmpty);
  });

  test('shares survive a restart', () async {
    await mac.engine.setShares('server/s1', {'phone'});
    final again = ShareEngine(data: mac.data, store: mac.store);
    await again.load();
    expect(again.sharesOf('server/s1'), {'phone'});
  });

  test('what an earlier version stored from others is removed on load', () async {
    phone.data.values.addAll({'server/mine': {'host': 'p'}, 'server/s1': {'host': 'a'}});
    phone.store.raw = jsonEncode({
      'shares': {},
      'received': {
        'mac': {'server/s1': 'hash'},
      },
    });
    final engine = ShareEngine(data: phone.data, store: phone.store);
    expect(await engine.load(), {'server/s1'});
    expect(phone.data.values.keys, ['server/mine']);
  });

  test('what the first, two-way version brought in from others is dropped', () async {
    phone.data.values.addAll({'server/mine': {'host': 'p'}, 'server/s1': {'host': 'a'}});
    final ledger = jsonEncode({
      'entries': {
        'server/mine': {'t': 1, 'by': 'phone', 'd': false, 'h': ''},
        'server/s1': {'t': 2, 'by': 'mac', 'd': false, 'h': ''},
      },
    });
    expect(await phone.engine.dropSyncedFromOthers(ledger, 'phone'), {'server/s1'});
    expect(phone.data.values.keys, ['server/mine']);
  });
}
