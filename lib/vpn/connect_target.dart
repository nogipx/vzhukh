import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../models/tunnel_route.dart';
import '../storage/app_set_repository.dart';
import '../storage/plain_store.dart';
import '../storage/route_repository.dart';
import '../storage/server_repository.dart';
import '../sync/received_items.dart';
import 'connection_ref.dart';
import 'route_resolver.dart';
import 'vpn_controller.dart';

/// What the main screen's Connect button connects: a server or a route,
/// this device's own or one a paired device shares.
@immutable
class ConnectTarget {
  const ConnectTarget.server(this.id, this.label) : isRoute = false;
  const ConnectTarget.route(this.id, this.label) : isRoute = true;

  final bool isRoute;
  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is ConnectTarget && other.isRoute == isRoute && other.id == id;

  @override
  int get hashCode => Object.hash(isRoute, id);

  Map<String, dynamic> toJson() => {'route': isRoute, 'id': id, 'label': label};

  static ConnectTarget fromJson(Map<String, dynamic> j) => j['route'] == true
      ? ConnectTarget.route(j['id'] as String, j['label'] as String)
      : ConnectTarget.server(j['id'] as String, j['label'] as String);
}

/// The target the user picked last, kept across launches. Device-local.
class SelectedTarget extends ValueNotifier<ConnectTarget?> {
  SelectedTarget._() : super(null) {
    plainStore.read(key: _key).then((raw) {
      if (raw != null && value == null) {
        try {
          value = ConnectTarget.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
        } catch (_) {}
      }
    });
  }

  static final instance = SelectedTarget._();
  static const _key = 'connect_target';

  void select(ConnectTarget target) {
    value = target;
    plainStore.write(key: _key, value: jsonEncode(target.toJson()));
  }
}

/// One thing the Connect button can connect: a route or a server, with
/// what the lists show about it.
@immutable
class ConnectChoice {
  const ConnectChoice(
    this.target, {
    this.route,
    this.server,
    this.own = false,
    this.canConnect = true,
  });

  final ConnectTarget target;
  final TunnelRoute? route;
  final Server? server;

  /// This device's own, not shared by a paired device.
  final bool own;

  /// False for a server with no key on this device.
  final bool canConnect;

  String get shareKey => route != null ? 'route/${route!.id}' : 'server/${server!.id}';

  String get detail {
    final r = route;
    if (r != null) return r.hops.length == 1 ? 'Direct (1 hop)' : '${r.hops.length} hops';
    return '${server!.host}:${server!.port}';
  }

  /// The saved pick while it is still in [choices], else the first that can
  /// connect.
  static ConnectChoice? current(List<ConnectChoice> choices) {
    final picked = SelectedTarget.instance.value;
    return choices.where((c) => c.target == picked && c.canConnect).firstOrNull ??
        choices.where((c) => c.canConnect).firstOrNull;
  }
}

/// Everything the Connect button can connect: servers, then routes, own
/// before what paired devices share.
class ListConnectChoices {
  const ListConnectChoices();

  Future<List<ConnectChoice>> call() async {
    final repo = ServerRepository();
    final servers = await repo.getServers();
    final routes = await RouteRepository().getRoutes();
    final received = ReceivedItems.instance;
    final keyed = <String>{
      for (final s in servers)
        if ([...await repo.getConnections(s.id), ...received.connections(s.id)]
            .any((c) => c.canConnect))
          s.id,
    };
    return [
      for (final s in servers)
        ConnectChoice(
          ConnectTarget.server(s.id, s.nickname),
          server: s,
          own: true,
          canConnect: keyed.contains(s.id),
        ),
      for (final r in received.servers)
        if (!servers.any((own) => own.id == r.value.id))
          ConnectChoice(
            ConnectTarget.server(r.value.id, r.value.nickname),
            server: r.value,
            canConnect: received.connections(r.value.id).any((c) => c.canConnect),
          ),
      for (final r in routes)
        ConnectChoice(ConnectTarget.route(r.id, r.label), route: r, own: true),
      for (final r in received.routes)
        if (!routes.any((own) => own.id == r.value.id))
          ConnectChoice(ConnectTarget.route(r.value.id, r.value.label), route: r.value),
    ];
  }
}

/// Connects [target]: the hops it stands for, with its app set.
class ConnectToTarget {
  const ConnectToTarget();

  Future<void> call(VpnController vpn, ConnectTarget target) async {
    final servers = ServerRepository();
    final appSets = AppSetRepository();
    final received = ReceivedItems.instance;

    if (target.isRoute) {
      final route = (await RouteRepository().getRoutes()).where((r) => r.id == target.id).firstOrNull ??
          received.route(target.id) ??
          (throw Exception('"${target.label}" is not available'));
      await vpn.connect(
        await RouteResolver(servers).resolve(route),
        routing: await appSets.configOf(await appSets.localChoice('route/${route.id}') ?? route.appSetId),
        ref: ConnectionRef.route(route.id, label: route.label),
      );
      return;
    }

    final server = (await servers.getServers()).where((s) => s.id == target.id).firstOrNull ??
        received.server(target.id) ??
        (throw Exception('"${target.label}" is not available'));
    final connection = [
      ...await servers.getConnections(server.id),
      ...received.connections(server.id),
    ].where((c) => c.canConnect).firstOrNull;
    if (connection == null) {
      throw Exception('There is no key to connect to "${server.nickname}" on this device');
    }
    await vpn.connect(
      [
        ResolvedHop(
          server: server,
          identity: SshIdentity(
            id: connection.id,
            serverId: connection.serverId,
            username: connection.username,
            authType: SshAuthType.privateKey,
            isAdmin: false,
            privateKeyPem: connection.privateKeyPem,
          ),
        ),
      ],
      routing: await appSets.configOf(
          await appSets.localChoice('server/${server.id}') ?? await appSets.serverSet(server.id)),
      ref: ConnectionRef.server(server.id, connection.id, label: server.nickname),
    );
  }
}
