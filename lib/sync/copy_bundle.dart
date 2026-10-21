import 'dart:math';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import 'share_engine.dart';

/// Admin access to a server, or null when the user does not give it.
typedef AdminFor = Future<SshIdentity?> Function(Server server);

/// Makes a new user and key on [server] and returns the connection with its
/// private key (AddConnection).
typedef ProvisionKey = Future<Connection> Function(Server server, SshIdentity admin, String label);

/// The owner did not give admin access to a server the copy needs.
class CopyCancelled implements Exception {
  const CopyCancelled(this.server);
  final String server;
  @override
  String toString() => 'No admin access to $server';
}

/// Builds the copy of an own [item] that a paired device asked to keep.
///
/// A copy never carries the owner's own key. For every server in it, a new
/// user with a key of its own is made on the server, and the copy gets that
/// key; the owner keeps the public half, so the copy can be revoked on its
/// own like any connection given to a friend. Rule sets and app sets have no
/// keys and are copied as they are.
class BuildCopyBundle {
  const BuildCopyBundle({required this.data, required this.provision});

  final SyncedData data;
  final ProvisionKey provision;

  Future<List<Map<String, dynamic>>> call(
    String item, {
    required String peerName,
    required AdminFor adminFor,
  }) async {
    final snapshot = await data.snapshot();
    final value = snapshot[item];
    if (value == null) throw StateError('$item no longer exists');

    final out = <String, Object?>{
      for (final k in data.closure(snapshot, item))
        if (!k.startsWith('conn/') && snapshot.containsKey(k)) k: snapshot[k],
    };

    final serverIds = switch (item.split('/').first) {
      'server' => [item.substring('server/'.length)],
      'route' => [
          for (final h in (value as Map)['hops'] as List) (h as Map)['serverId'] as String,
        ],
      _ => const <String>[],
    };

    final suffix = Random.secure().nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    final keys = <String, String>{};
    for (final id in serverIds.toSet()) {
      final server = Server.fromJson(Map<String, dynamic>.from(snapshot['server/$id'] as Map));
      final admin = await adminFor(server);
      if (admin == null) throw CopyCancelled(server.nickname);
      final connection = await provision(server, admin, '$peerName copy $suffix');
      out['conn/$id/${connection.id}'] = connection.toJson();
      keys[id] = connection.id;
    }

    if (item.startsWith('route/')) {
      final route = Map<String, dynamic>.from(value as Map);
      route['hops'] = [
        for (final h in route['hops'] as List)
          {...(h as Map), 'connectionId': keys[h['serverId']]},
      ];
      out[item] = route;
    }

    return [
      for (final MapEntry(:key, :value) in out.entries) {'k': key, 'v': value},
    ];
  }
}
