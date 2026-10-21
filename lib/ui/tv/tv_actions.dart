import 'package:flutter/material.dart';

import '../action_sheet.dart';
import '../theme/app_theme.dart';
import 'tv_focusable.dart';

/// One row of a TV list: an icon, a title, a line under it and something on
/// the right, on the card surface. The whole row takes focus.
class TvRow extends StatelessWidget {
  const TvRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.iconColor,
    this.trailing,
    this.titleColor,
    this.onPressed,
    this.onLongPress,
    this.autofocus = false,
    this.focusNode,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// Shown instead of [icon], such as an app's own icon.
  final Widget? leading;
  final Color? iconColor;
  final Color? titleColor;
  final Widget? trailing;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      enabled: enabled,
      onPressed: onPressed,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
        ),
        child: Row(
          children: [
            if (leading != null || icon != null) ...[
              leading ?? Icon(icon, color: iconColor ?? scheme.onSurfaceVariant),
              const SizedBox(width: AppSpacing.lg),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium?.copyWith(color: titleColor)),
                  if (subtitle != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.md),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// The TV form of [showActionSheet]: a dialog of rows the D-pad moves
/// through, the first one focused. The chosen action runs after the dialog
/// is gone.
Future<void> showTvActions(
  BuildContext context, {
  String? title,
  required List<SheetAction> actions,
}) async {
  final rows = actions.where((a) => !a.divider).toList();
  final chosen = await showDialog<SheetAction>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final scheme = theme.colorScheme;
      return Dialog(
        insetPadding: TvInsets.overscan,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 0, AppSpacing.sm, AppSpacing.md),
                      child: Text(title, style: theme.textTheme.headlineSmall),
                    ),
                  for (var i = 0; i < rows.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: TvRow(
                        autofocus: i == 0,
                        icon: rows[i].checked ? Icons.check : rows[i].icon,
                        iconColor: rows[i].destructive
                            ? scheme.error
                            : rows[i].checked
                                ? scheme.primary
                                : null,
                        title: rows[i].label,
                        titleColor: rows[i].destructive ? scheme.error : null,
                        subtitle: rows[i].subtitle,
                        onPressed: () => Navigator.pop(ctx, rows[i]),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  chosen?.onSelected();
}

/// A full TV screen: a title, an optional action on the right of it, and
/// the content, all inside the area a set does not crop. Back leaves it.
class TvPage extends StatelessWidget {
  const TvPage({super.key, required this.title, this.subtitle, this.action, required this.child});

  final String title;
  final String? subtitle;
  final Widget? action;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Padding(
        padding: TvInsets.overscan,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.headlineMedium),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  ?action,
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// A row and a "more" button beside it, the pattern for items that have
/// actions besides the one OK does. The button is reached by pressing right.
class TvRowWithMore extends StatelessWidget {
  const TvRowWithMore({super.key, required this.row, required this.onMore});

  final Widget row;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: row),
          TvFocusable(
            onPressed: onMore,
            child: Container(
              width: 80,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
              ),
              child: Icon(Icons.more_horiz, size: 28, color: scheme.onSurfaceVariant, semanticLabel: 'More'),
            ),
          ),
        ],
      ),
    );
  }
}
