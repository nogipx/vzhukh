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
    this.focusNode,
    this.filled = true,
    this.destructive = false,
    this.minWidth = 340,
    this.compact = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool filled;
  final bool destructive;
  final double minWidth;

  /// Smaller, for secondary actions next to a main one.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = destructive ? scheme.error : scheme.primary;
    final foreground = filled ? scheme.onPrimary : (destructive ? accent : scheme.onSurface);

    return TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onPressed: onPressed,
      // A Container with an alignment expands to whatever it is given, which
      // stretches the button across the pane. IntrinsicWidth pins it back to
      // the label while the minimum keeps short labels comfortably large.
      child: IntrinsicWidth(
        child: Container(
          constraints: BoxConstraints(minWidth: minWidth, minHeight: compact ? 56 : 76),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? AppSpacing.lg : AppSpacing.xl,
            vertical: compact ? AppSpacing.sm : AppSpacing.md,
          ),
          decoration: BoxDecoration(
            color: filled ? accent : Colors.transparent,
            border: filled ? null : Border.all(color: scheme.outlineVariant, width: 2),
            borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, color: foreground, size: compact ? 22 : 28),
                SizedBox(width: compact ? AppSpacing.sm : AppSpacing.md),
              ],
              Text(
                label,
                style: (compact ? theme.textTheme.titleMedium : theme.textTheme.titleLarge)?.copyWith(
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
