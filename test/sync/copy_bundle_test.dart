import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/models/connection.dart';
import 'package:vzhukh/models/server.dart';
import 'package:vzhukh/models/ssh_identity.dart';
import 'package:vzhukh/sync/copy_bundle.dart';
import 'package:vzhukh/sync/repository_synced_data.dart';
import 'package:vzhukh/sync/share_engine.dart';

/// The real key layout, from a map.
class _Data implements SyncedData {
  _Data(this.values);
  final Map<String, Object?> values;
  @override
  Future<Map<String, Object?>> snapshot() async => Map.of(values);
  @override
  Future<void> apply(List<MapEntry<String, Object?>> batch) async {}
  @override
  Set<String> closure(Map<String, Object?> snapshot, String item) =>
      RepositorySyncedData().closure(snapshot, item);
}

Map<String, dynamic> conn(String server, String id, {String? key}) => Connection(
      id: id,
      serverId: server,
      label: id,
      username: 'vzhukh_$id',
      publicKeyOpenSSH: 'ssh-ed25519 AAAA $id',
      privateKeyPem: key,
      createdAt: DateTime(2026),
    ).toJson();

void main() {
  final data = _Data({
    'server/s1': const Server(id: 's1', host: 'a', port: 22, nickname: 'home').toJson(),
    'conn/s1/owner': conn('s1', 'owner', key: 'OWNER KEY'),
    'conn/s1/alice': conn('s1', 'alice'),
    'server/s2': const Server(id: 's2', host: 'b', port: 22, nickname: 'kz').toJson(),
    'conn/s2/owner2': conn('s2', 'owner2', key: 'OWNER KEY 2'),
    'route/r1': {
      'id': 'r1',
      'label': 'via kz',
      'hops': [
        {'serverId': 's2', 'connectionId': 'owner2'},
        {'serverId': 's1', 'connectionId': 'owner'},
      ],
    },
    'ruleset/w': {'id': 'w', 'name': 'Work', 'rules': {}},
  });

  final provisioned = <String>[];
  Future<Connection> provision(Server server, SshIdentity admin, String label) async {
    provisioned.add('${server.id}:$label:${admin.password}');
    return Connection.fromJson(conn(server.id, 'new_${server.id}', key: 'NEW KEY ${server.id}'));
  }

  Future<SshIdentity?> admin(Server server) async => SshIdentity(
        id: 'a',
        serverId: server.id,
        username: 'root',
        authType: SshAuthType.password,
        isAdmin: true,
        password: 'pw',
      );

  Map<String, Object?> asMap(List<Map<String, dynamic>> bundle) =>
      {for (final e in bundle) e['k'] as String: e['v']};

  setUp(provisioned.clear);

  test('a server copy carries a new key, none of the owner\'s', () async {
    final bundle = asMap(await BuildCopyBundle(data: data, provision: provision)(
      'server/s1',
      peerName: 'Pixel',
      adminFor: admin,
    ));
    expect(bundle.keys, unorderedEquals(['server/s1', 'conn/s1/new_s1']));
    expect((bundle['conn/s1/new_s1'] as Map)['privateKeyPem'], 'NEW KEY s1');
    expect(provisioned.single, startsWith('s1:Pixel copy '));
    expect(provisioned.single, endsWith(':pw'));
  });

  test('a route copy gets a key on each of its servers, and its hops use them', () async {
    final bundle = asMap(await BuildCopyBundle(data: data, provision: provision)(
      'route/r1',
      peerName: 'Pixel',
      adminFor: admin,
    ));
    expect(bundle.keys,
        unorderedEquals(['route/r1', 'server/s1', 'server/s2', 'conn/s1/new_s1', 'conn/s2/new_s2']));
    expect((bundle['route/r1'] as Map)['hops'], [
      {'serverId': 's2', 'connectionId': 'new_s2'},
      {'serverId': 's1', 'connectionId': 'new_s1'},
    ]);
    expect(provisioned, hasLength(2));
  });

  test('without admin access there is no copy', () async {
    await expectLater(
      BuildCopyBundle(data: data, provision: provision)(
        'server/s1',
        peerName: 'Pixel',
        adminFor: (_) async => null,
      ),
      throwsA(isA<CopyCancelled>()),
    );
    expect(provisioned, isEmpty);
  });

  test('a set is copied as it is, with no key made', () async {
    final bundle = asMap(await BuildCopyBundle(data: data, provision: provision)(
      'ruleset/w',
      peerName: 'Pixel',
      adminFor: (_) => fail('no admin needed'),
    ));
    expect(bundle.keys, ['ruleset/w']);
    expect(provisioned, isEmpty);
  });
}
