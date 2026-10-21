import 'dart:io';

import 'package:flutter/material.dart';

import 'theme/app_theme.dart';

/// One choice in an action sheet.
class SheetAction {
  const SheetAction(
    this.label,
    this.onSelected, {
    this.icon,
    this.subtitle,
    this.destructive = false,
    this.checked = false,
  }) : divider = false;

  const SheetAction.divider()
      : label = '',
        onSelected = _none,
        icon = null,
        subtitle = null,
        destructive = false,
        checked = false,
        divider = true;

  static void _none() {}

  final String label;
  final VoidCallback onSelected;
  final IconData? icon;
  final String? subtitle;
  final bool destructive;

  /// Marks the current one of several options.
  final bool checked;
  final bool divider;
}

/// Asks which of [actions] to run: a bottom sheet on a phone, a dialog on
/// macOS, where sheets rising from the bottom of a wide window look lost.
/// The chosen action runs after the sheet is gone, so it can push screens
/// or open dialogs of its own.
Future<void> showActionSheet(
  BuildContext context, {
  String? title,
  required List<SheetAction> actions,
}) async {
  final theme = Theme.of(context);

  Widget tile(BuildContext ctx, SheetAction a) {
    if (a.divider) return const Divider(height: 1);
    final color = a.destructive ? theme.colorScheme.error : null;
    return ListTile(
      leading: a.icon == null ? null : Icon(a.icon, color: color),
      title: Text(a.label, style: TextStyle(color: color)),
      subtitle: a.subtitle == null ? null : Text(a.subtitle!),
      // The current option is marked, not coloured whole.
      trailing: a.checked ? Icon(Icons.check, color: theme.colorScheme.primary) : null,
      onTap: () => Navigator.pop(ctx, a),
    );
  }

  final SheetAction? chosen;
  if (Platform.isMacOS) {
    chosen = await showDialog<SheetAction>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: title == null ? null : Text(title),
        contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 320),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (final a in actions) tile(ctx, a)],
            ),
          ),
        ],
      ),
    );
  } else {
    chosen = await showModalBottomSheet<SheetAction>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
              for (final a in actions) tile(ctx, a),
            ],
          ),
        ),
      ),
    );
  }
  chosen?.onSelected();
}

/// A "more" button that opens an action sheet. With [child], the child is
/// what gets tapped instead of the icon.
class ActionSheetButton extends StatelessWidget {
  const ActionSheetButton({
    super.key,
    required this.actions,
    this.title,
    this.tooltip = 'More',
    this.icon = Icons.more_vert,
    this.child,
  });

  /// Built on tap, so it reflects the state at that moment.
  final List<SheetAction> Function() actions;
  final String? title;
  final String tooltip;
  final IconData icon;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    void open() => showActionSheet(context, title: title, actions: actions());
    final child = this.child;
    if (child == null) {
      return IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: open);
    }
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: open,
        child: Padding(padding: const EdgeInsets.all(AppSpacing.sm), child: child),
      ),
    );
  }
}
