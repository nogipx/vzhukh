import 'dart:async';

import 'package:flutter/material.dart';

import '../storage/route_repository.dart';
import '../storage/server_repository.dart';
import '../sync/sync_signal.dart';
import '../vpn/connect_target.dart';
import '../vpn/vpn_controller.dart';
import 'about.dart';
import 'action_sheet.dart';
import 'add_server_screen.dart';
import 'export_route_screen.dart';
import 'import_invite_screen.dart';
import 'import_route_screen.dart';
import 'lan_sync_screen.dart';
import 'route_edit_screen.dart';
import 'server_detail_screen.dart';
import 'common/widgets.dart';
import 'theme/app_theme.dart';

/// The main screen: servers and routes, one picked, connected with one
/// button.
class ServerListScreen extends StatefulWidget {
  final VpnController vpn;

  const ServerListScreen({super.key, required this.vpn});

  @override
  State<ServerListScreen> createState() => _ServerListScreenState();
}

class _ServerListScreenState extends State<ServerListScreen> {
  final _repo = ServerRepository();
  final _routeRepo = RouteRepository();
  List<ConnectChoice> _choices = [];

  /// Keys and app sets change on screens pushed over this one.
  StreamSubscription<void>? _localSub;

  @override
  void initState() {
    super.initState();
    _load();
    SyncSignal.instance.remote.addListener(_load);
    _localSub = SyncSignal.instance.localChanges.listen((_) => _load());
  }

  @override
  void dispose() {
    SyncSignal.instance.remote.removeListener(_load);
    _localSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final choices = await const ListConnectChoices()();
    if (mounted) setState(() => _choices = choices);
  }

  Future<void> _connect(ConnectTarget target) async {
    SelectedTarget.instance.select(target);
    try {
      await const ConnectToTarget()(widget.vpn, target);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), error: true);
    }
  }

  /// Picking only picks, unless a tunnel is running: then it would name one
  /// target while the tunnel runs another, so the tunnel moves too.
  Future<void> _pick(ConnectTarget target, ConnectTarget? current) async {
    if (target == current) return;
    if (widget.vpn.status.value.isLive) {
      await _connect(target);
    } else {
      SelectedTarget.instance.select(target);
    }
  }

  Future<void> _push(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    await _load();
  }

  Future<void> _add() => showActionSheet(
        context,
        title: 'Add',
        actions: [
          SheetAction('Add server', () => _push(const AddServerScreen()),
              icon: Icons.dns_outlined),
          SheetAction('New route', () => _push(const RouteEditScreen()),
              icon: Icons.route_outlined, subtitle: 'Through several servers in a chain'),
          SheetAction('Scan invite', () => _push(const ImportInviteScreen()),
              icon: Icons.qr_code_scanner),
          SheetAction('Scan route', () => _push(const ImportRouteScreen()),
              icon: Icons.qr_code_scanner),
        ],
      );

  /// Never leaves a tunnel running through something that is gone.
  Future<void> _delete(ConnectChoice c, {required bool isCurrent}) async {
    final server = c.server;
    final ok = server != null
        ? await confirmDestructive(context,
            title: 'Delete server?', message: 'Remove "${server.nickname}" and all its keys?')
        : await confirmDestructive(context,
            title: 'Delete route?', message: 'Remove "${c.target.label}"?');
    if (!ok) return;
    if (isCurrent && widget.vpn.status.value.isLive) {
      await widget.vpn.disconnect();
    }
    if (server != null) {
      await _repo.deleteServer(server.id);
    } else {
      await _routeRepo.deleteRoute(c.route!.id);
    }
    await _load();
  }

  List<SheetAction> _menu(ConnectChoice c, {required bool isCurrent}) {
    if (!c.own) return const [];
    final route = c.route;
    return [
      SheetAction('Share with my devices',
          () => showShareDialog(context, c.shareKey, c.target.label), icon: Icons.devices),
      if (route != null) ...[
        SheetAction('Share via QR', () => _push(ExportRouteScreen(route: route)),
            icon: Icons.qr_code),
      ],
      SheetAction('Delete', () => _delete(c, isCurrent: isCurrent),
          icon: Icons.delete_outline, destructive: true),
    ];
  }

  VoidCallback? _detail(ConnectChoice c) {
    if (!c.own) return null;
    final server = c.server;
    if (server != null) return () => _push(ServerDetailScreen(server: server));
    return () => _push(RouteEditScreen(existing: c.route));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vzhukh'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About Vzhukh',
            onPressed: () => showAbout(context, widget.vpn),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: SelectedTarget.instance,
        builder: (context, _) {
          final choices = _choices;
          if (choices.isEmpty) {
            return const EmptyState(
              icon: Icons.dns_outlined,
              title: 'No servers yet',
              message: 'Tap + to add a server or scan an invite.',
            );
          }
          final current = ConnectChoice.current(choices);
          final servers = choices.where((c) => c.server != null);
          final routes = choices.where((c) => c.route != null);

          Widget tile(ConnectChoice c) {
            final isCurrent = c.target == current?.target;
            return _ChoiceTile(
              choice: c,
              selected: isCurrent,
              onPick: () => _pick(c.target, current?.target),
              onDetail: _detail(c),
              menu: _menu(c, isCurrent: isCurrent),
            );
          }

          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                child: _ConnectCard(
                  vpn: widget.vpn,
                  choice: current,
                  onConnect: _connect,
                ),
              ),
              if (servers.isNotEmpty) ...[
                const SectionHeader('Servers'),
                for (final c in servers) tile(c),
              ],
              if (routes.isNotEmpty) ...[
                const SectionHeader('Routes'),
                for (final c in routes) tile(c),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Status, the picked target and the one button that connects it.
class _ConnectCard extends StatelessWidget {
  const _ConnectCard({
    required this.vpn,
    required this.choice,
    required this.onConnect,
  });

  final VpnController vpn;
  final ConnectChoice? choice;
  final ValueChanged<ConnectTarget> onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picked = choice;
    return ValueListenableBuilder(
      valueListenable: vpn.status,
      builder: (context, status, _) {
        final busy = status == VpnStatus.connecting || status == VpnStatus.reconnecting;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(alignment: Alignment.centerLeft, child: StatusBadge(status: status)),
                const SizedBox(height: AppSpacing.md),
                Text(
                  picked?.target.label ?? 'Nothing to connect',
                  style: theme.textTheme.headlineSmall,
                ),
                Text(
                  picked == null
                      ? 'No route or server here has a key on this device'
                      : picked.detail,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.lg),
                (status.isLive ? FilledButton.tonalIcon : FilledButton.icon)(
                  onPressed: status.isLive
                      ? vpn.disconnect
                      : picked == null
                          ? null
                          : () => onConnect(picked.target),
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(status.isLive ? Icons.stop : Icons.play_arrow),
                  label: Text(switch (status) {
                    VpnStatus.connected => 'Disconnect',
                    VpnStatus.connecting || VpnStatus.reconnecting => 'Cancel',
                    _ => 'Connect',
                  }),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  ),
                ),
                // A connection that keeps retrying says why, instead of
                // spinning with no explanation.
                if (status != VpnStatus.connected && status != VpnStatus.disconnected)
                  ValueListenableBuilder(
                    valueListenable: vpn.errorMessage,
                    builder: (_, msg, _) => msg == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: AppSpacing.sm),
                            child: Text(
                              msg,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(color: status.color(context)),
                            ),
                          ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A row of the picker. Tapping picks it; a server without a key on this
/// device cannot be picked and opens its details instead.
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.choice,
    required this.selected,
    required this.onPick,
    this.onDetail,
    this.menu = const [],
  });

  final ConnectChoice choice;
  final bool selected;
  final VoidCallback onPick;

  /// Server details, or the route's editor.
  final VoidCallback? onDetail;
  final List<SheetAction> menu;

  @override
  Widget build(BuildContext context) {
    final c = choice;
    return ListTile(
      // Only the radio mark carries the accent; the text stays plain.
      leading: Icon(
        !c.canConnect
            ? Icons.key_off_outlined
            : selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(c.target.label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.canConnect ? c.detail : '${c.detail} · no key on this device'),
          c.own ? ShareStatusLabel(c.shareKey) : ShareStatusLabel.received(c.shareKey),
        ],
      ),
      trailing: onDetail == null && menu.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (menu.isNotEmpty)
                  ActionSheetButton(title: c.target.label, actions: () => menu),
                if (onDetail != null)
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    tooltip: c.route != null ? 'Edit' : 'Details',
                    onPressed: onDetail,
                  ),
              ],
            ),
      onTap: c.canConnect ? onPick : onDetail,
      onLongPress: menu.isEmpty
          ? null
          : () => showActionSheet(context, title: c.target.label, actions: menu),
    );
  }
}
