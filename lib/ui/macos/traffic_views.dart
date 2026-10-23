import 'dart:math';

import 'package:flutter/material.dart';

import '../../daemon/daemon_models.dart';
import '../../daemon/traffic_analysis.dart';
import '../theme/app_theme.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String formatRate(double perSecond) => perSecond < 1 ? '' : '${formatBytes(perSecond.round())}/s';

String formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inHours}h ${d.inMinutes % 60}m';
}

/// "12s ago", "4m ago", or the time for anything older than an hour.
String formatAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 5) return 'now';
  if (d.inMinutes < 1) return '${d.inSeconds}s ago';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// Colour and icon of an action, the same everywhere traffic is shown.
({IconData icon, Color color}) actionStyle(BuildContext context, String action) {
  final c = AppColors.of(context);
  return switch (action) {
    'route' => (icon: Icons.vpn_lock, color: Theme.of(context).colorScheme.primary),
    'direct' => (icon: Icons.arrow_outward, color: c.info),
    'block' => (icon: Icons.block, color: c.danger),
    'vpn' || 'system' => (icon: Icons.business, color: c.warning),
    _ => (icon: Icons.help_outline, color: c.muted),
  };
}

TextStyle _numbers(BuildContext context) => Theme.of(context).textTheme.bodySmall!.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

/// Bytes a minute over the last hour: download up, upload down, the way
/// Activity Monitor draws network.
class TrafficChart extends StatelessWidget {
  const TrafficChart({super.key, required this.points});

  final List<FlowStatPoint> points;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peak = points.fold<int>(1, (m, p) => max(m, max(p.download, p.upload)));
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: CustomPaint(
              painter: _ChartPainter(points, peak, scheme.primary, AppColors.of(context).info),
              size: Size.infinite,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 140,
            child: Text(
              'last hour\npeak ${formatBytes(peak)}/min',
              textAlign: TextAlign.right,
              style: _numbers(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.points, this.peak, this.down, this.up);

  final List<FlowStatPoint> points;
  final int peak;
  final Color down;
  final Color up;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final mid = size.height / 2;
    final w = size.width / points.length;
    final pDown = Paint()..color = down;
    final pUp = Paint()..color = up;
    final axis = Paint()
      ..color = down.withValues(alpha: 0.2)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), axis);
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final x = i * w;
      final hd = p.download / peak * (mid - 1);
      final hu = p.upload / peak * (mid - 1);
      if (hd > 0) canvas.drawRect(Rect.fromLTWH(x, mid - hd, max(w - 1, 1), hd), pDown);
      if (hu > 0) canvas.drawRect(Rect.fromLTWH(x, mid, max(w - 1, 1), hu), pUp);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.points != points || old.peak != peak;
}

/// Left of the table: the commonest values of each dimension in what is
/// shown, with their bytes. A click filters to that value, another undoes.
class TrafficFacets extends StatelessWidget {
  const TrafficFacets({
    super.key,
    required this.rows,
    required this.query,
    required this.display,
    required this.onToggle,
  });

  final List<TrafficRow> rows;
  final TrafficQuery query;
  final String Function(TrafficDim, String) display;
  final void Function(TrafficDim, String) onToggle;

  static const _dims = [
    TrafficDim.action,
    TrafficDim.route,
    TrafficDim.app,
    TrafficDim.site,
    TrafficDim.port,
    TrafficDim.rule,
    TrafficDim.network,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      children: [
        for (final dim in _dims) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
            child: Text(dim.label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          for (final g in const GroupTraffic()(rows, dim).take(8))
            _FacetLine(
              label: display(dim, g.value),
              bytes: g.totals.bytes,
              errors: g.totals.errors,
              selected: query.has(dim, dim == TrafficDim.route || dim == TrafficDim.rule ? display(dim, g.value) : g.value),
              onTap: () => onToggle(dim, dim == TrafficDim.route || dim == TrafficDim.rule ? display(dim, g.value) : g.value),
            ),
        ],
      ],
    );
  }
}

class _FacetLine extends StatelessWidget {
  const _FacetLine({required this.label, required this.bytes, required this.errors, required this.selected, required this.onTap});

  final String label;
  final int bytes;
  final int errors;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? scheme.primary.withValues(alpha: 0.12) : null,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: selected ? scheme.primary : null),
              ),
            ),
            if (errors > 0)
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.xs),
                child: Text('$errors err', style: _numbers(context).copyWith(color: AppColors.of(context).danger)),
              ),
            Text(formatBytes(bytes), style: _numbers(context)),
          ],
        ),
      ),
    );
  }
}

/// The table's columns, and which one it is sorted by.
class TrafficTableHeader extends StatelessWidget {
  const TrafficTableHeader({super.key, required this.sort, required this.live, required this.onSort, required this.title});

  final TrafficSort sort;
  final bool live;
  final ValueChanged<TrafficSort> onSort;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget col(String label, TrafficSort s, double width, {bool left = false}) {
      final on = sort == s;
      final text = Text(
        label,
        textAlign: left ? TextAlign.left : TextAlign.right,
        style: theme.textTheme.labelMedium?.copyWith(
          color: on ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
          fontWeight: on ? FontWeight.w600 : null,
        ),
      );
      return InkWell(
        onTap: () => onSort(s),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: width == 0 ? text : SizedBox(width: width, child: text),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        children: [
          Expanded(child: Align(alignment: Alignment.centerLeft, child: col(title, TrafficSort.name, 0, left: true))),
          col('Conns', TrafficSort.conns, _TrafficColumns.conns),
          col('Errors', TrafficSort.errors, _TrafficColumns.errors),
          col('Sent', TrafficSort.sent, _TrafficColumns.bytes),
          col('Received', TrafficSort.received, _TrafficColumns.bytes),
          if (live) col('Now', TrafficSort.rate, _TrafficColumns.rate),
          col('Last', TrafficSort.last, _TrafficColumns.last),
        ],
      ),
    );
  }
}

abstract final class _TrafficColumns {
  static const double conns = 64;
  static const double errors = 64;
  static const double bytes = 96;
  static const double rate = 96;
  static const double last = 80;
}

/// One line of the grouped table.
class TrafficGroupLine extends StatelessWidget {
  const TrafficGroupLine({
    super.key,
    required this.group,
    required this.label,
    required this.expandable,
    required this.expanded,
    required this.selected,
    required this.live,
    required this.onTap,
    required this.onToggle,
  });

  final TrafficGroup group;
  final String label;
  final bool expandable;
  final bool expanded;
  final bool selected;
  final bool live;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = group.totals;
    final numbers = _numbers(context);
    final colors = AppColors.of(context);
    final action = group.dim == TrafficDim.action ? actionStyle(context, group.value) : null;
    return InkWell(
      onTap: onTap,
      onDoubleTap: expandable ? onToggle : null,
      child: Container(
        color: selected ? scheme.primary.withValues(alpha: 0.12) : null,
        padding: EdgeInsets.only(left: AppSpacing.md + group.depth * 20.0, right: AppSpacing.md),
        height: 28,
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: expandable
                  ? InkWell(
                      onTap: onToggle,
                      child: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
                    )
                  : null,
            ),
            if (action != null) ...[
              Icon(action.icon, size: 14, color: action.color),
              const SizedBox(width: AppSpacing.xs),
            ],
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: label),
                  if (t.open > 0) TextSpan(text: '  ${t.open} open', style: numbers.copyWith(color: colors.success)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: group.depth == 0 ? FontWeight.w600 : null),
              ),
            ),
            SizedBox(width: _TrafficColumns.conns, child: Text('${t.conns}', textAlign: TextAlign.right, style: numbers)),
            SizedBox(
              width: _TrafficColumns.errors,
              child: Text(
                t.errors == 0 ? '' : '${t.errors}',
                textAlign: TextAlign.right,
                style: numbers.copyWith(color: colors.danger),
              ),
            ),
            SizedBox(width: _TrafficColumns.bytes, child: Text(formatBytes(t.upload), textAlign: TextAlign.right, style: numbers)),
            SizedBox(width: _TrafficColumns.bytes, child: Text(formatBytes(t.download), textAlign: TextAlign.right, style: numbers)),
            if (live)
              SizedBox(width: _TrafficColumns.rate, child: Text(formatRate(t.rate), textAlign: TextAlign.right, style: numbers)),
            SizedBox(width: _TrafficColumns.last, child: Text(formatAgo(t.last), textAlign: TextAlign.right, style: numbers)),
          ],
        ),
      ),
    );
  }
}

/// A heading and lines of label · value, the building block of the details
/// panel.
class TrafficSection extends StatelessWidget {
  const TrafficSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          ...children,
        ],
      ),
    );
  }
}

class TrafficKeyValue extends StatelessWidget {
  const TrafficKeyValue(this.label, this.value, {super.key, this.color, this.onTap});

  final String label;
  final String value;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(value, style: _numbers(context)),
        ],
      ),
    );
    return onTap == null ? line : InkWell(onTap: onTap, child: line);
  }
}
