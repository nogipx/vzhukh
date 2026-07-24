import 'package:flutter/material.dart';

import '../../models/tunnel_route.dart';
import '../../network/local_http_server.dart';
import '../../storage/route_repository.dart';
import '../../storage/server_repository.dart';
import '../../vpn/import_route_payload.dart';
import '../../vpn/route_resolver.dart';
import '../../vpn/vpn_controller.dart';
import '../network_receive_screen.dart';
import '../theme/app_theme.dart';
import 'tv_focusable.dart';
import 'tv_nav_rail.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
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

  Future<void> _receive() async {
    final payload = await Navigator.push<ReceivedPayload>(
      context,
      MaterialPageRoute(builder: (_) => const NetworkReceiveScreen()),
    );
    if (payload == null || !mounted) return;

    // Anything else is password protected or arrives by QR, neither of which
    // belongs on a remote control.
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
    return Scaffold(
      body: Padding(
        padding: TvInsets.overscan,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TvNavRail(
              destinations: _destinations,
              selectedIndex: _tab,
              onSelected: (i) => setState(() => _tab = i),
            ),
            Expanded(
              child: _tab == 0
                  ? _ConnectPane(
                      vpn: widget.vpn,
                      route: _selected,
                      onConnect: _connect,
                      onReceive: _receive,
                    )
                  : _RoutesPane(
                      routes: _routes,
                      selected: _selected,
                      onConnect: _connect,
                      onReceive: _receive,
                    ),
            ),
          ],
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
    required this.onConnect,
    required this.onReceive,
  });

  final VpnController vpn;
  final TunnelRoute? route;
  final ValueChanged<TunnelRoute> onConnect;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = route;

    if (current == null) {
      return _EmptyState(onReceive: onReceive);
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
              TvPrimaryButton(
                label: live ? 'Disconnect' : 'Connect',
                icon: live ? Icons.stop_rounded : Icons.play_arrow_rounded,
                autofocus: true,
                destructive: live,
                onPressed: () =>
                    live ? vpn.disconnect() : onConnect(current),
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
  const _EmptyState({required this.onReceive});

  final VoidCallback onReceive;

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
            TvPrimaryButton(
              label: 'Receive from phone',
              icon: Icons.wifi,
              autofocus: true,
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
    required this.onConnect,
    required this.onReceive,
  });

  final List<TunnelRoute> routes;
  final TunnelRoute? selected;
  final ValueChanged<TunnelRoute> onConnect;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) {
    if (routes.isEmpty) return _EmptyState(onReceive: onReceive);

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
              onPressed: () => onConnect(routes[i]),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.md),
          child: TvPrimaryButton(
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

class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.route,
    required this.active,
    required this.autofocus,
    required this.onPressed,
  });

  final TunnelRoute route;
  final bool active;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
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

/// Large, unmistakable action for the D-pad.
class TvPrimaryButton extends StatelessWidget {
  const TvPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.autofocus = false,
    this.filled = true,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool autofocus;
  final bool filled;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = destructive ? scheme.error : scheme.primary;

    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      // A Container with an alignment expands to whatever it is given, which
      // stretches the button across the pane. IntrinsicWidth pins it back to
      // the label while the minimum keeps small labels comfortably large.
      child: IntrinsicWidth(
        child: Container(
          constraints: const BoxConstraints(minWidth: 340, minHeight: 76),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            color: filled ? accent : Colors.transparent,
            border: filled ? null : Border.all(color: accent, width: 2),
            borderRadius: const BorderRadius.all(Radius.circular(16)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, color: filled ? scheme.onPrimary : accent, size: 28),
                const SizedBox(width: AppSpacing.md),
              ],
              Text(
                label,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: filled ? scheme.onPrimary : accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
