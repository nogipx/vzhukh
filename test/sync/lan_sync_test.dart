import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/sync/lan_sync.dart';
import 'package:vzhukh/sync/received_items.dart';
import 'package:vzhukh/sync/sync_crypto.dart';
import 'package:vzhukh/sync/share_engine.dart';

class _Data implements SyncedData {
  final values = <String, Object?>{};

  @override
  Future<Map<String, Object?>> snapshot() async => Map.of(values);

  @override
  Future<void> apply(List<MapEntry<String, Object?>> batch) async {
    for (final e in batch) {
      e.value == null ? values.remove(e.key) : values[e.key] = e.value;
    }
  }

  @override
  Set<String> closure(Map<String, Object?> snapshot, String item) => {item};
}

class _Mem implements SyncIdentityStore, LedgerStore {
  String? raw;
  @override
  Future<String?> read() async => raw;
  @override
  Future<void> write(String raw) async => this.raw = raw;
}

Future<void> eventually(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('condition not met in 5s');
}

Future<int> post(int port, String path, Object body) async {
  final client = HttpClient();
  try {
    final request = await client.post('127.0.0.1', port, path);
    request.write(jsonEncode(body));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close();
  }
}

void main() {
  late _Data macData, phoneData;
  late ReceivedItems phoneGot;
  late LanSync mac, phone;

  setUp(() async {
    macData = _Data();
    phoneData = _Data();
    phoneGot = ReceivedItems();
    mac = LanSync(
        data: macData, state: _Mem(), received: ReceivedItems(), identity: _Mem(), mdns: false, name: 'Mac');
    phone = LanSync(
        data: phoneData, state: _Mem(), received: phoneGot, identity: _Mem(), mdns: false, name: 'Phone');
    await mac.start();
    await phone.start();
    mac.see(NearbyDevice(key: phone.key, name: 'Phone', host: '127.0.0.1', port: phone.port!));
    phone.see(NearbyDevice(key: mac.key, name: 'Mac', host: '127.0.0.1', port: mac.port!));
  });

  tearDown(() async {
    await mac.stop();
    await phone.stop();
  });

  test('the asked device shows a passkey; typed on the other, both pair and sync', () async {
    macData.values['route/1'] = {'label': 'home'};

    final pairing = await mac.pair(mac.nearby.single);
    final incoming = phone.incoming.value!;
    expect(incoming.name, 'Mac');

    await pairing.enter(incoming.passkey);
    expect(incoming.state.value, PairingState.paired);
    expect(phone.incoming.value, isNull);
    expect(mac.paired.single.name, 'Phone');
    await eventually(() => phone.paired.isNotEmpty);
    expect(phone.paired.single.name, 'Mac');

    // Pairing shares nothing by itself.
    await mac.syncNow();
    expect(phoneGot.isEmpty, isTrue);

    await mac.share('route/1', {phone.key});
    await eventually(() => phoneGot.ownerOf('route/1') == mac.key);
    expect(mac.sharedWith('route/1'), ['Phone']);
    expect(phone.receivedFrom('route/1'), 'Mac');
    expect(phoneData.values, isEmpty, reason: 'what is received is not stored');

    await mac.share('route/1', {});
    await eventually(() => phoneGot.isEmpty);
  });

  Future<void> pairUp() async {
    final pairing = await mac.pair(mac.nearby.single);
    await pairing.enter(phone.incoming.value!.passkey);
    await eventually(() => phone.paired.isNotEmpty);
  }

  test("the owner's things are hidden while it is away", () async {
    macData.values['route/1'] = {'label': 'home'};
    await pairUp();
    await mac.share('route/1', {phone.key});
    await eventually(() => !phoneGot.isEmpty);

    await mac.stop();
    await phone.syncNow();
    expect(phoneGot.isEmpty, isTrue);

    await mac.start();
    phone.see(NearbyDevice(key: mac.key, name: 'Mac', host: '127.0.0.1', port: mac.port!));
    await phone.syncNow();
    expect(phoneGot.ownerOf('route/1'), mac.key);
  });

  test('a TV keeps what it was shared while the owner is away and after a restart', () async {
    await phone.stop();
    final identity = _Mem(), state = _Mem(), kept = _Mem();
    final tvGot = ReceivedItems();
    LanSync tv() => LanSync(
        data: phoneData, state: state, received: tvGot, identity: identity, retained: kept, mdns: false, name: 'TV');
    phone = tv();
    await phone.start();
    mac.see(NearbyDevice(key: phone.key, name: 'TV', host: '127.0.0.1', port: phone.port!));
    phone.see(NearbyDevice(key: mac.key, name: 'Mac', host: '127.0.0.1', port: mac.port!));

    macData.values['route/1'] = {'label': 'home'};
    final pairing = await mac.pair(mac.nearby.singleWhere((d) => d.name == 'TV'));
    await pairing.enter(phone.incoming.value!.passkey);
    await eventually(() => phone.paired.isNotEmpty);
    await mac.share('route/1', {phone.key});
    await eventually(() => tvGot.ownerOf('route/1') == mac.key);

    await mac.stop();
    await phone.syncNow();
    expect(tvGot.ownerOf('route/1'), mac.key, reason: 'kept while the owner is away');

    await phone.stop();
    tvGot.set({}, {});
    phone = tv();
    await phone.start();
    expect(tvGot.ownerOf('route/1'), mac.key, reason: 'published again at start');
    await mac.start();
  });

  test('a copy asked for and allowed stays when the owner goes', () async {
    macData.values['ruleset/1'] = {'name': 'Work'};
    await pairUp();
    await mac.share('ruleset/1', {phone.key});
    await eventually(() => !phoneGot.isEmpty);

    await phone.requestCopy('ruleset/1');
    expect(phone.copyRequested('ruleset/1'), isTrue);
    final request = mac.copyRequest.value!;
    expect(request.peerName, 'Phone');
    expect(request.title, 'ruleset/1');
    await request.allow((_) async => null);
    await eventually(() => phoneData.values.containsKey('ruleset/1'));
    expect(phone.copyRequested('ruleset/1'), isFalse);

    await mac.stop();
    await phone.syncNow();
    expect(phoneData.values, {'ruleset/1': {'name': 'Work'}});
  });

  test('a copy denied leaves it shared as before', () async {
    macData.values['route/1'] = {'label': 'home'};
    await pairUp();
    await mac.share('route/1', {phone.key});
    await eventually(() => !phoneGot.isEmpty);

    await phone.requestCopy('route/1');
    mac.copyRequest.value!.deny();
    await eventually(() => !phone.copyRequested('route/1'));
    expect(phone.receivedFrom('route/1'), 'Mac');
    expect(phoneData.values, isEmpty);
  });

  test('a wrong passkey pairs nobody and ends the session', () async {
    final pairing = await mac.pair(mac.nearby.single);
    final incoming = phone.incoming.value!;
    final wrong = (incoming.passkey + 1) % 1000000;

    await expectLater(pairing.enter(wrong), throwsA(isA<PairingFailed>()));
    expect(incoming.state.value, PairingState.failed);
    expect(mac.paired, isEmpty);
    expect(phone.paired, isEmpty);

    // The right passkey is no use once the session has failed.
    await expectLater(pairing.enter(incoming.passkey), throwsA(isA<PairingFailed>()));
    expect(phone.paired, isEmpty);
  });

  test('cancelling on the asked device ends the pairing', () async {
    final pairing = await mac.pair(mac.nearby.single);
    final incoming = phone.incoming.value!;
    incoming.cancel();
    expect(incoming.state.value, PairingState.cancelled);
    await expectLater(pairing.enter(incoming.passkey), throwsA(isA<PairingFailed>()));
    expect(mac.paired, isEmpty);
  });

  test('a device that is not paired is refused', () async {
    final stranger = b64(randomBytes(32));
    expect(await post(phone.port!, '/sync', {'from': stranger, 'box': 'x'}), 403);
  });
}
