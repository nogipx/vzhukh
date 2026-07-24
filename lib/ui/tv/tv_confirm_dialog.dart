import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'tv_button.dart';

/// Asks a yes/no question in a form that reads from the sofa.
///
/// Material's dialog buttons are small text targets whose focus state barely
/// registers across a room, so the choices are full buttons and the safe one
/// takes focus first — a stray press on a remote should never destroy
/// anything.
Future<bool> showTvConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return Dialog(
        backgroundColor: theme.colorScheme.surface,
        insetPadding: TvInsets.overscan,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: AppSpacing.md),
                Text(
                  message,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TvButton(
                      label: cancelLabel,
                      filled: false,
                      autofocus: true,
                      minWidth: 220,
                      onPressed: () => Navigator.pop(ctx, false),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    TvButton(
                      label: confirmLabel,
                      destructive: destructive,
                      minWidth: 220,
                      onPressed: () => Navigator.pop(ctx, true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  return result ?? false;
}
