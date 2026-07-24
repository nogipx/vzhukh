import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'tv_focusable.dart';

class TvNavDestination {
  const TvNavDestination({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// Left-hand navigation for the TV shell.
///
/// A bottom bar is a thumb pattern; on a 16:9 panel driven by a D-pad the
/// natural gesture is pressing left out of the content, so navigation lives
/// on the left edge and keeps its labels visible.
class TvNavRail extends StatelessWidget {
  const TvNavRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<TvNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: TvInsets.railWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.xl,
            ),
            child: Text(
              'Vzhukh',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (var i = 0; i < destinations.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _RailItem(
                destination: destinations[i],
                selected: i == selectedIndex,
                autofocus: i == selectedIndex,
                onPressed: () => onSelected(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.autofocus,
    required this.onPressed,
  });

  final TvNavDestination destination;
  final bool selected;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Selection and focus are different things on a TV: selection is which
    // tab is showing, focus is where the D-pad cursor sits. They must stay
    // visually distinct, so selection uses a fill and focus uses the ring.
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;

    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        ),
        child: Row(
          children: [
            Icon(destination.icon, color: foreground),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                destination.label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
