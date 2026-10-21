import 'package:flutter/material.dart';

import '../../vpn/vpn_controller.dart';
import '../theme/app_theme.dart';

/// How a tunnel status reads and looks, the same in every shell.
extension VpnStatusLook on VpnStatus {
  String get label => switch (this) {
        VpnStatus.disconnected => 'Disconnected',
        VpnStatus.connecting => 'Connecting…',
        VpnStatus.connected => 'Connected',
        VpnStatus.reconnecting => 'Reconnecting…',
        VpnStatus.error => 'Error',
      };

  Color color(BuildContext context) {
    final c = AppColors.of(context);
    return switch (this) {
      VpnStatus.disconnected => c.muted,
      VpnStatus.connecting || VpnStatus.reconnecting => c.warning,
      VpnStatus.connected => c.success,
      VpnStatus.error => c.danger,
    };
  }
}

/// A dot and the status in words.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final VpnStatus status;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall!;
    final color = status.color(context);
    final dot = (style.fontSize ?? 14) * 0.6;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: dot,
          height: dot,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(status.label, style: style.copyWith(color: color)),
      ],
    );
  }
}

/// A small heading between parts of a list.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.padding});
  final String text;

  /// Where the heading sits; by default in line with list tiles.
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.xs),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// What a screen shows when it has nothing to list.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.message, this.icon});

  final String title;
  final String? message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 40, color: muted),
                const SizedBox(height: AppSpacing.md),
              ],
              Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              if (message != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A short message at the bottom of the screen. [error] is for what failed,
/// [warning] for what worked only in part.
void showToast(BuildContext context, String message, {bool error = false, bool warning = false}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(
      message,
      style: error
          ? TextStyle(color: scheme.onErrorContainer)
          : warning
              ? TextStyle(color: AppColors.of(context).warning)
              : null,
    ),
    backgroundColor: error ? scheme.errorContainer : null,
  ));
}

/// Asks before something that cannot be undone. True when confirmed.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ) ==
    true;
