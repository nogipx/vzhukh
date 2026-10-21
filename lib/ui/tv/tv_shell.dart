import 'package:flutter/material.dart';

import '../../storage/app_set_repository.dart';
import '../../storage/route_repository.dart';
import '../../storage/server_repository.dart';
import '../../sync/lan_sync.dart';
import '../../sync/received_items.dart';
import '../../sync/sync_signal.dart';
import '../../vpn/connect_target.dart';
import '../../vpn/vpn_controller.dart';
import '../action_sheet.dart';
import '../app_set_picker_screen.dart';
import '../common/widgets.dart';
import '../theme/app_theme.dart';
import 'tv_actions.dart';
import 'tv_app_sets.dart';
import 'tv_button.dart';
import 'tv_confirm_dialog.dart';
import 'tv_devices_screen.dart';
import 'tv_focusable.dart';
import 'tv_settings_screen.dart';

/// The television shell: one screen, the status and the Connect button on
/// the left, what can be connected on the right.
///
/// A TV is a consumer of servers and routes, never an administrator of
/// them: it has no camera for invite codes and typing a host and password
/// on a remote is punishing. The phone pairs with it and shares what it
/// should use; the TV keeps that after the phone leaves (LanSync.init).
class TvShell extends StatefulWidget {
  const TvShell({super.key, required this.vpn});

  final VpnController vpn;

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  List<ConnectChoice> _choices = [];

  /// False until what the TV kept is loaded: until then an empty list may
  /// only be not loaded yet, and saying there is nothing would be wrong.
  bool _loaded = false;

  /// The Connect button. Picking something hands focus to it, so pick, OK,
  /// and the tunnel is up.
  final _connectFocus = FocusNode(debugLabel: 'tv-connect');

  @override
  void initState() {
    super.initState();
    _load();
    SyncSignal.instance.remote.addListener(_load);
    LanSync.instance.ready.then((_) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    SyncSignal.instance.remote.removeListener(_load);
    _connectFocus.dispose();
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

  /// Choosing only chooses; connecting stays behind the one big button.
  /// Fusing the two would mean a stray press on a remote tears down a
  /// working tunnel. While a tunnel runs, though, naming one target on
  /// screen and running another would be a lie, so the session moves too.
  Future<void> _pick(ConnectChoice choice) async {
    final wasLive = widget.vpn.status.value.isLive;
    final changed = choice.target != ConnectChoice.current(_choices)?.target;
    SelectedTarget.instance.select(choice.target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _connectFocus.canRequestFocus) _connectFocus.requestFocus();
    });
    if (wasLive && changed) await _connect(choice.target);
  }

  Future<void> _delete(ConnectChoice choice, {required bool isCurrent}) async {
    final confirmed = await showTvConfirmDialog(
      context,
      title: choice.server != null ? 'Delete server?' : 'Delete route?',
      message: 'Remove "${choice.target.label}" from this device.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;

    // Never leave a tunnel running through something that is gone.
    if (isCurrent && widget.vpn.status.value.isLive) {
      await widget.vpn.disconnect();
    }
    if (choice.server case final server?) {
      await ServerRepository().deleteServer(server.id);
    } else {
      await RouteRepository().deleteRoute(choice.route!.id);
    }
    await _load();
    if (mounted) showToast(context, 'Deleted "${choice.target.label}".');
  }

  Future<void> _push(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    await _load();
  }

  /// Everything else about [choice], behind OK on its menu button or a long
  /// press on the card.
  Future<void> _menu(ConnectChoice choice, {required bool isCurrent}) async {
    final appSets = AppSetRepository();
    final local = await appSets.localChoice(choice.shareKey);
    final setId = local ??
        (choice.route != null ? choice.route!.appSetId : await appSets.serverSet(choice.server!.id));
    final set = await appSets.find(setId);
    if (!mounted) return;
    final owner = ReceivedItems.instance.ownerNameOf(choice.shareKey);
    final sync = LanSync.instance;
    await showTvActions(
      context,
      title: choice.target.label,
      actions: [
        SheetAction('Apps through the tunnel', () => _pickApps(choice, setId),
            icon: Icons.apps, subtitle: set?.name ?? 'All apps'),
        SheetAction('Details', () => _details(choice, owner), icon: Icons.info_outline),
        if (!choice.own && !sync.copyRequested(choice.shareKey))
          SheetAction('Keep a copy with its own key', () => _requestCopy(choice, owner),
              icon: Icons.download_outlined,
              subtitle: 'Works without ${owner ?? 'the owner'} for good; allow it there'),
        if (choice.own)
          SheetAction('Delete', () => _delete(choice, isCurrent: isCurrent),
              icon: Icons.delete_outline, destructive: true),
      ],
    );
  }

  Future<void> _pickApps(ConnectChoice choice, String? current) async {
    final picked = await Navigator.push<AppSetChoice>(
      context,
      MaterialPageRoute(builder: (_) => TvAppSetScreen(selected: current)),
    );
    if (picked == null) return;
    await AppSetRepository().setLocalChoice(choice.shareKey, picked.id);
    // A running tunnel takes the new list only when it starts again.
    if (choice.target == ConnectChoice.current(_choices)?.target && widget.vpn.status.value.isLive) {
      await _connect(choice.target);
    }
  }

  /// Read-only facts, as rows so the D-pad can scroll them.
  Future<void> _details(ConnectChoice choice, String? owner) async {
    final route = choice.route;
    final server = choice.server;
    final own = await ServerRepository().getServers();
    String serverName(String id) =>
        own.where((s) => s.id == id).firstOrNull?.nickname ??
        ReceivedItems.instance.server(id)?.nickname ??
        id;
    if (!mounted) return;
    await showTvActions(
      context,
      title: choice.target.label,
      actions: [
        if (server != null)
          SheetAction('Address', () {}, icon: Icons.dns_outlined, subtitle: '${server.host}:${server.port}'),
        if (route != null)
          for (final (i, hop) in route.hops.indexed)
            SheetAction('Hop ${i + 1}', () {}, icon: Icons.route_outlined, subtitle: serverName(hop.serverId)),
        SheetAction('Owner', () {}, icon: Icons.person_outline, subtitle: owner ?? 'This TV'),
      ],
    );
  }

  Future<void> _requestCopy(ConnectChoice choice, String? owner) async {
    try {
      await LanSync.instance.requestCopy(choice.shareKey);
      if (mounted) showToast(context, 'Asked ${owner ?? 'the owner'}. Allow it there.');
    } catch (e) {
      if (mounted) showToast(context, 'Could not ask ${owner ?? 'the owner'}: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: TvInsets.overscan,
        child: ListenableBuilder(
          listenable: SelectedTarget.instance,
          builder: (context, _) {
            if (_choices.isEmpty && !_loaded) {
              return const Center(child: CircularProgressIndicator());
            }
            if (_choices.isEmpty) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const EmptyState(
                    icon: Icons.settings_input_antenna,
                    title: 'Nothing to connect yet',
                    message: 'Pair your phone with this TV under Devices, then share a '
                        'server or a route with it there. The TV keeps what it was '
                        'shared, also when the phone is away.',
                  ),
                  _SecondaryButtons(
                    // Nothing else here takes focus; a remote needs a start.
                    autofocus: true,
                    onDevices: () => _push(const TvDevicesScreen()),
                    onSettings: () => _push(const TvSettingsScreen()),
                  ),
                ],
              );
            }
            final current = ConnectChoice.current(_choices);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 5,
                  child: _ConnectPane(
                    vpn: widget.vpn,
                    choice: current,
                    focusNode: _connectFocus,
                    onConnect: _connect,
                    onDevices: () => _push(const TvDevicesScreen()),
                    onSettings: () => _push(const TvSettingsScreen()),
                  ),
                ),
                const SizedBox(width: AppSpacing.xl),
                Expanded(
                  flex: 6,
                  child: _ChoiceList(
                    choices: _choices,
                    current: current,
                    onPick: _pick,
                    onMenu: (c) => _menu(c, isCurrent: c.target == current?.target),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Status, the picked target and the one big action.
class _ConnectPane extends StatelessWidget {
  const _ConnectPane({
    required this.vpn,
    required this.choice,
    required this.focusNode,
    required this.onConnect,
    required this.onDevices,
    required this.onSettings,
  });

  final VpnController vpn;
  final ConnectChoice? choice;
  final FocusNode focusNode;
  final ValueChanged<ConnectTarget> onConnect;
  final VoidCallback onDevices;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picked = choice;

    return ValueListenableBuilder<VpnStatus>(
      valueListenable: vpn.status,
      builder: (context, status, _) {
        final live = status.isLive;
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              StatusBadge(status: status),
              const SizedBox(height: AppSpacing.lg),
              Text(
                picked?.target.label ?? 'Nothing to connect',
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                picked == null ? 'Nothing here has a key on this device' : picked.detail,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              TvButton(
                label: live ? 'Disconnect' : 'Connect',
                icon: live ? Icons.stop_rounded : Icons.play_arrow_rounded,
                autofocus: true,
                focusNode: focusNode,
                filled: !live,
                onPressed: () {
                  if (live) {
                    vpn.disconnect();
                  } else if (picked != null) {
                    onConnect(picked.target);
                  }
                },
              ),
              const SizedBox(height: AppSpacing.md),
              _SecondaryButtons(onDevices: onDevices, onSettings: onSettings),
              const SizedBox(height: AppSpacing.lg),
              ValueListenableBuilder<String?>(
                valueListenable: vpn.errorMessage,
                builder: (context, error, _) {
                  if (error == null || status == VpnStatus.connected || status == VpnStatus.disconnected) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    error,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: status.color(context)),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChoiceList extends StatelessWidget {
  const _ChoiceList({
    required this.choices,
    required this.current,
    required this.onPick,
    required this.onMenu,
  });

  final List<ConnectChoice> choices;
  final ConnectChoice? current;
  final ValueChanged<ConnectChoice> onPick;
  final ValueChanged<ConnectChoice> onMenu;

  @override
  Widget build(BuildContext context) {
    final servers = choices.where((c) => c.server != null);
    final routes = choices.where((c) => c.route != null);
    Widget card(ConnectChoice c) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: _ChoiceCard(
            choice: c,
            active: c.target == current?.target,
            onPressed: () => onPick(c),
            onMenu: () => onMenu(c),
          ),
        );
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      children: [
        if (servers.isNotEmpty) ...[
          const SectionHeader('Servers', padding: _headerPadding),
          for (final c in servers) card(c),
        ],
        if (routes.isNotEmpty) ...[
          const SectionHeader('Routes', padding: _headerPadding),
          for (final c in routes) card(c),
        ],
      ],
    );
  }
}

/// Section headings line up with the cards' left edge, past the focus
/// ring's room.
const _headerPadding = EdgeInsets.fromLTRB(
    AppFocus.ringWidth + AppFocus.gap, AppSpacing.md, 0, AppSpacing.xs);

/// A server or route, and a button with everything else about it.
///
/// The menu is a visible sibling reached by pressing right rather than only
/// a hidden hold: a remote gives no hint that holding does anything, and a
/// viewer should not have to discover it. Holding works too.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.choice,
    required this.active,
    required this.onPressed,
    required this.onMenu,
  });

  final ConnectChoice choice;
  final bool active;
  final VoidCallback onPressed;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surface = scheme.surfaceContainerLow;
    final c = choice;
    final owner = ReceivedItems.instance.ownerNameOf(c.shareKey);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: TvFocusable(
              // Without a key there is nothing to pick; OK opens the menu.
              onPressed: c.canConnect ? onPressed : onMenu,
              onLongPress: onMenu,
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
                ),
                child: Row(
                  children: [
                    Icon(
                      !c.canConnect
                          ? Icons.key_off_outlined
                          : active
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                      color: active ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.target.label, style: theme.textTheme.titleLarge),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            [
                              c.detail,
                              if (!c.canConnect) 'no key on this device',
                              if (owner != null) 'from $owner',
                            ].join(' · '),
                            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          TvFocusable(
            onPressed: onMenu,
            child: Container(
              width: 88,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: surface,
                borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
              ),
              child: Icon(Icons.more_horiz, size: 32, color: scheme.onSurfaceVariant, semanticLabel: 'More'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Devices and Settings, small and below the main action.
class _SecondaryButtons extends StatelessWidget {
  const _SecondaryButtons({required this.onDevices, required this.onSettings, this.autofocus = false});

  final VoidCallback onDevices;
  final VoidCallback onSettings;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        TvButton(
          label: 'Devices',
          icon: Icons.devices,
          filled: false,
          compact: true,
          minWidth: 0,
          autofocus: autofocus,
          onPressed: onDevices,
        ),
        TvButton(
          label: 'Settings',
          icon: Icons.settings_outlined,
          filled: false,
          compact: true,
          minWidth: 0,
          onPressed: onSettings,
        ),
      ],
    );
  }
}

