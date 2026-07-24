import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'tv_focusable.dart';

/// Large, unmistakable action for the D-pad.
class TvButton extends StatelessWidget {
  const TvButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.autofocus = false,
    this.filled = true,
    this.destructive = false,
    this.minWidth = 340,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool autofocus;
  final bool filled;
  final bool destructive;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = destructive ? scheme.error : scheme.primary;
    final foreground = filled ? scheme.onPrimary : accent;

    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      // A Container with an alignment expands to whatever it is given, which
      // stretches the button across the pane. IntrinsicWidth pins it back to
      // the label while the minimum keeps short labels comfortably large.
      child: IntrinsicWidth(
        child: Container(
          constraints: BoxConstraints(minWidth: minWidth, minHeight: 76),
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
                Icon(icon, color: foreground, size: 28),
                const SizedBox(width: AppSpacing.md),
              ],
              Text(
                label,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: foreground,
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
