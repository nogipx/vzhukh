import 'package:flutter/material.dart';

import '../../models/tunnel_route.dart';
import '../../network/local_http_server.dart';
import '../../storage/route_repository.dart';
import '../../storage/server_repository.dart';
import '../../vpn/import_route_payload.dart';
import '../../vpn/route_resolver.dart';
import '../../vpn/vpn_controller.dart';
import '../theme/app_theme.dart';
import 'tv_button.dart';
import 'tv_confirm_dialog.dart';
import 'tv_focusable.dart';
import 'tv_nav_rail.dart';
import 'tv_receive_screen.dart';

/// The television shell.
///
/// A TV is a consumer of routes, never an administrator of them: it has no
/// camera for invite codes and typing a host and password on a remote is
/// punishing. Provisioning stays on the phone, which hands routes over the
/// local network, so nothing here needs the on-screen keyboard.
class TvShell extends StatefulWidget {
  const TvShell({super.key, required this.vpn});

  final VpnController vpn;

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  static const _destinations = [
    TvNavDestination(icon: Icons.power_settings_new, label: 'Connect'),
    TvNavDestination(icon: Icons.route_outlined, label: 'Routes'),
  ];

  final _routeRepo = RouteRepository();
  final _serverRepo = ServerRepository();
  late final _resolver = RouteResolver(_serverRepo);
  late final _importRoute = ImportRoutePayload(_serverRepo, _routeRepo);

  List<TunnelRoute> _routes = [];
  TunnelRoute? _selected;
  int _tab = 0;

  /// Focus is handed to whichever control the open pane treats as its starting
  /// point. This is a plain node rather than a separate [FocusScope] on the
  /// content: a scope confines directional traversal to itself, which trapped
  /// the D-pad inside the pane and left no way back to the rail.
  final _contentFocus = FocusNode(debugLabel: 'tv-content-primary');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _contentFocus.dispose();
    super.dispose();
  }

  void _selectTab(int index) {
    setState(() => _tab = index);
    _focusContentSoon();
  }

  /// Hands focus to the pane once it has been laid out, so the pane that just
  /// opened is what lights up.
  void _focusContentSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _contentFocus.canRequestFocus) _contentFocus.requestFocus();
    });
  }

  Future<void> _load() async {
    final routes = await _routeRepo.getRoutes();
    if (!mounted) return;
    setState(() {
      _routes = routes;
      _selected = routes.where((r) => r.id == _selected?.id).firstOrNull ??
          routes.firstOrNull;
    });
  }

  Future<void> _connect(TunnelRoute route) async {
    setState(() => _selected = route);
    try {
      final hops = await _resolver.resolve(route);
      await widget.vpn.connect(hops, routing: route.routing);
    } catch (e) {
      if (mounted) _toast(e.toString(), error: true);
    }
  }

  /// Choosing a route only chooses it; connecting stays behind the one big
  /// button on the status pane. Fusing the two would mean a stray press on a
  /// remote tears down a working tunnel.
  Future<void> _selectRoute(TunnelRoute route) async {
    final wasLive = widget.vpn.status.value != VpnStatus.disconnected;
    setState(() {
      _selected = route;
      _tab = 0;
    });
    _focusContentSoon();

    // Naming one route on screen while the tunnel runs another would be a lie,
    // so switching during a session moves the session too.
    if (wasLive) await _connect(route);
  }

  Future<void> _deleteRoute(TunnelRoute route) async {
    final confirmed = await showTvConfirmDialog(
      context,
      title: 'Delete route?',
      message: 'Remove "${route.label}" from this device.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;

    // Never leave a tunnel running for a route that no longer exists.
    if (route.id == _selected?.id &&
        widget.vpn.status.value != VpnStatus.disconnected) {
      await widget.vpn.disconnect();
    }

    await _routeRepo.deleteRoute(route.id);
    await _load();
    if (mounted) _toast('Deleted "${route.label}".');
  }

  Future<void> _receive() async {
    final payload = await Navigator.push<ReceivedPayload>(
      context,
      MaterialPageRoute(builder: (_) => const TvReceiveScreen()),
    );
    if (payload == null || !mounted) return;

    // Anything else is password protected, and entering a password on a remote
    // is exactly what this shell avoids.
    if (payload.type != 'route_plain') {
      _toast('Send this one from the phone as a route.', error: true);
      return;
    }

    try {
      final route = await _importRoute(payload.data);
      await _load();
      if (mounted) {
        setState(() => _selected = route);
        _toast('Added "${route.label}".');
      }
    } catch (e) {
      if (mounted) _toast('Import failed: $e', error: true);
    }
  }

  void _toast(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Back is the only way out on a remote. From a secondary tab it should
    // return to the status pane; only there does it leave the app.
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _selectTab(0);
      },
      child: Scaffold(
        body: Padding(
          padding: TvInsets.overscan,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TvNavRail(
                destinations: _destinations,
                selectedIndex: _tab,
                onSelected: _selectTab,
              ),
              Expanded(
                child: _tab == 0
                    ? _ConnectPane(
                        vpn: widget.vpn,
                        route: _selected,
                        primaryFocus: _contentFocus,
                        onConnect: _connect,
                        onReceive: _receive,
                        onChangeRoute: () => _selectTab(1),
                      )
                    : _RoutesPane(
                        routes: _routes,
                        selected: _selected,
                        primaryFocus: _contentFocus,
                        onConnect: _selectRoute,
                        onDelete: _deleteRoute,
                        onReceive: _receive,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Status plus a single large action — the only thing most sessions need.
class _ConnectPane extends StatelessWidget {
  const _ConnectPane({
    required this.vpn,
    required this.route,
    required this.primaryFocus,
    required this.onConnect,
    required this.onReceive,
    required this.onChangeRoute,
  });

  final VpnController vpn;
  final TunnelRoute? route;
  final FocusNode primaryFocus;
  final ValueChanged<TunnelRoute> onConnect;
  final VoidCallback onReceive;
  final VoidCallback onChangeRoute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = route;

    if (current == null) {
      return _EmptyState(onReceive: onReceive, primaryFocus: primaryFocus);
    }

    return ValueListenableBuilder<VpnStatus>(
      valueListenable: vpn.status,
      builder: (context, status, _) {
        final busy = status == VpnStatus.connecting ||
            status == VpnStatus.reconnecting;
        final live = status == VpnStatus.connected || busy;

        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StatusBadge(status: status),
              const SizedBox(height: AppSpacing.lg),
              Text(
                current.label,
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                current.hops.length == 1
                    ? 'Direct · 1 hop'
                    : '${current.hops.length} hops',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              TvButton(
                label: live ? 'Disconnect' : 'Connect',
                icon: live ? Icons.stop_rounded : Icons.play_arrow_rounded,
                autofocus: true,
                focusNode: primaryFocus,
                destructive: live,
                onPressed: () =>
                    live ? vpn.disconnect() : onConnect(current),
              ),
              const SizedBox(height: AppSpacing.md),
              TvButton(
                label: 'Change route',
                icon: Icons.swap_horiz,
                filled: false,
                onPressed: onChangeRoute,
              ),
              const SizedBox(height: AppSpacing.lg),
              ValueListenableBuilder<String?>(
                valueListenable: vpn.errorMessage,
                builder: (context, error, _) {
                  if (error == null || status != VpnStatus.error) {
                    return const SizedBox.shrink();
                  }
                  return ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Text(
                      error,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onReceive, required this.primaryFocus});

  final VoidCallback onReceive;
  final FocusNode primaryFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.settings_input_antenna,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'No route yet',
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Open Vzhukh on your phone, pick a route and send it to this '
              'device over the local network.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            TvButton(
              label: 'Receive from phone',
              icon: Icons.wifi,
              autofocus: true,
              focusNode: primaryFocus,
              onPressed: onReceive,
            ),
          ],
        ),
      ),
    );
  }
}

class _RoutesPane extends StatelessWidget {
  const _RoutesPane({
    required this.routes,
    required this.selected,
    required this.primaryFocus,
    required this.onConnect,
    required this.onDelete,
    required this.onReceive,
  });

  final List<TunnelRoute> routes;
  final TunnelRoute? selected;
  final FocusNode primaryFocus;
  final ValueChanged<TunnelRoute> onConnect;
  final ValueChanged<TunnelRoute> onDelete;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) {
    if (routes.isEmpty) {
      return _EmptyState(onReceive: onReceive, primaryFocus: primaryFocus);
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      children: [
        for (var i = 0; i < routes.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: _RouteCard(
              route: routes[i],
              active: routes[i].id == selected?.id,
              autofocus: i == 0,
              focusNode: i == 0 ? primaryFocus : null,
              onPressed: () => onConnect(routes[i]),
              onDelete: () => onDelete(routes[i]),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg),
          child: TvButton(
            label: 'Receive from phone',
            icon: Icons.wifi,
            filled: false,
            onPressed: onReceive,
          ),
        ),
      ],
    );
  }
}

/// A route, plus its own delete control.
///
/// The delete affordance is a visible sibling reached by pressing right rather
/// than a hidden hold-to-delete: a remote gives no hint that holding does
/// anything, and a viewer should not have to discover it.
class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.route,
    required this.active,
    required this.autofocus,
    required this.focusNode,
    required this.onPressed,
    required this.onDelete,
  });

  final TunnelRoute route;
  final bool active;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onPressed;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surface = scheme.surfaceContainerHighest.withValues(alpha: 0.4);

    return Row(
      children: [
        Expanded(
          child: TvFocusable(
            autofocus: autofocus,
            focusNode: focusNode,
            onPressed: onPressed,
            onLongPress: onDelete,
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: const BorderRadius.all(Radius.circular(16)),
              ),
              child: Row(
                children: [
                  Icon(
                    active ? Icons.check_circle : Icons.route_outlined,
                    color: active ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(route.label, style: theme.textTheme.titleLarge),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          route.hops.length == 1
                              ? 'Direct · 1 hop'
                              : '${route.hops.length} hops',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        TvFocusable(
          onPressed: onDelete,
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          child: Container(
            width: 96,
            height: 96,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: surface,
              borderRadius: const BorderRadius.all(Radius.circular(16)),
            ),
            child: Icon(
              Icons.delete_outline,
              size: 32,
              color: scheme.error,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final VpnStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (Color color, String label) = switch (status) {
      VpnStatus.connected => (const Color(0xFF4CAF50), 'Connected'),
      VpnStatus.connecting => (const Color(0xFFFFB300), 'Connecting…'),
      VpnStatus.reconnecting => (const Color(0xFFFFB300), 'Reconnecting…'),
      VpnStatus.error => (scheme.error, 'Error'),
      VpnStatus.disconnected => (scheme.onSurfaceVariant, 'Disconnected'),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 16),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Text(
          label,
          style: theme.textTheme.headlineSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}
