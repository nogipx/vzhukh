import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../daemon/daemon_installer.dart';
import '../../daemon/daemon_models.dart';
import '../../daemon/traffic_analysis.dart';
import '../../models/routing_rule.dart';
import '../../storage/routing_rules_repository.dart';
import '../../vpn/macos_daemon_backend.dart';
import '../../vpn/vpn_controller.dart';
import '../action_sheet.dart';
import '../common/widgets.dart';
import '../set_transfer.dart';
import '../theme/app_theme.dart';
import 'rule_edit_screen.dart';
import 'traffic_views.dart';

/// What the daemon did with traffic, to be looked at from any side: by
/// app, site, host, port, decision, route or rule, over the open
/// connections or the last hour. Connections, not requests: what is inside
/// HTTPS is not seen.
class TrafficScreen extends StatefulWidget {
  final VpnController vpn;

  /// Opens the rule editor with a prefilled rule.
  final void Function(RoutingRule draft) onMakeRule;

  /// Whether its tab is the one shown. Hidden, it does not poll the helper.
  final bool visible;

  const TrafficScreen({super.key, required this.vpn, required this.onMakeRule, this.visible = true});

  @override
  State<TrafficScreen> createState() => _TrafficScreenState();
}

/// How much of the past the table sums.
enum _Window {
  live('Open now', 0),
  m5('5 min', 5),
  m15('15 min', 15),
  h1('1 hour', 60),
  all('Since clear', 0);

  const _Window(this.label, this.minutes);
  final String label;
  final int minutes;
}

/// Filters that answer common questions in one click.
const _presets = <(String, String)>[
  ('Everything', ''),
  ('Past the tunnel', 'action:direct,system'),
  ('Errors', 'err'),
  ('Blocked', 'action:block'),
  ('Open', 'open'),
];

class _TrafficScreenState extends State<TrafficScreen> {
  static const _keepClosed = 1000;

  MacDaemonBackend get _mac => widget.vpn.macDaemon!;
  final _rulesRepo = RoutingRulesRepository();
  final _queryCtrl = TextEditingController();

  Timer? _poll;
  int _ticks = 0;
  int _seq = 0;
  List<FlowRecord> _active = [];
  List<FlowRecord> _closed = [];

  /// The bytes each open connection had at the previous poll, for its rate.
  Map<int, (int, int, DateTime)> _previous = {};
  Map<int, (double, double)> _rates = {};

  FlowStats? _stats;

  /// False once the helper answered that it has no statistics: an older
  /// one. The table then sums the recent connections it still keeps.
  bool _statsSupported = true;

  Map<String, String> _ruleNames = {};
  bool _paused = false;

  /// What the helper says about recording; null from one that always
  /// records.
  bool? _recording;
  DateTime? _recordingSince;

  late final AppLifecycleListener _lifecycle;
  bool _appShown = true;

  _Window _window = _Window.live;

  /// Set once the user picks a window; until then it follows recording.
  bool _windowPicked = false;
  TrafficQuery _query = TrafficQuery.empty;
  final List<TrafficDim> _chain = [TrafficDim.app, TrafficDim.site, TrafficDim.host];
  TrafficSort _sort = TrafficSort.received;
  final Set<String> _expanded = {};
  List<(TrafficDim, String)>? _selected;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onShow: () => _setShown(true),
      onHide: () => _setShown(false),
    );
    _updatePolling();
  }

  @override
  void didUpdateWidget(TrafficScreen old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) _updatePolling();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _lifecycle.dispose();
    _queryCtrl.dispose();
    super.dispose();
  }

  void _setShown(bool shown) {
    _appShown = shown;
    _updatePolling();
  }

  /// Polls only while the tab is on screen: the helper's answers are
  /// built, sent and parsed every second, for nothing when nobody looks.
  void _updatePolling() {
    final want = widget.visible && _appShown;
    if (want && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
      _refresh();
    } else if (!want) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _toggleRecording() async {
    final on = !(_recording ?? false);
    try {
      final snap = await _mac.client.setRecording(on);
      if (!mounted) return;
      setState(() {
        _recording = snap.recording;
        _recordingSince = snap.recordingSince;
        // What is recorded shows in full; open-only is what there is
        // without recording.
        if (on && _window == _Window.live) _window = _Window.all;
      });
      if (on && _statsSupported) await _refreshStats();
    } catch (e) {
      if (mounted) showToast(context, 'Update the helper to record: $e', warning: true);
    }
  }

  Future<void> _refresh() async {
    if (_paused || _mac.daemonStatus.value == null) return;
    final tick = _ticks++;
    if (tick % 10 == 0) {
      final rules = await _rulesRepo.load();
      _ruleNames = {for (final r in rules.rules) r.id: r.name};
    }
    try {
      final snap = await _mac.client.flows(since: _seq);
      final now = DateTime.now();
      final rates = <int, (double, double)>{};
      final previous = <int, (int, int, DateTime)>{};
      for (final f in snap.active) {
        previous[f.id] = (f.upload, f.download, now);
        final p = _previous[f.id];
        if (p != null) {
          final secs = now.difference(p.$3).inMilliseconds / 1000;
          if (secs > 0) rates[f.id] = ((f.upload - p.$1) / secs, (f.download - p.$2) / secs);
        }
      }
      if (!mounted) return;
      setState(() {
        if (snap.seq < _seq) _closed = []; // the daemon restarted
        _seq = snap.seq;
        _recording = snap.recording;
        _recordingSince = snap.recordingSince;
        if (!_windowPicked && snap.recording != false && _window == _Window.live) _window = _Window.all;
        _active = snap.active..sort((a, b) => b.started.compareTo(a.started));
        if (snap.closed.isNotEmpty) {
          _closed = [...snap.closed.reversed, ..._closed].take(_keepClosed).toList();
        }
        _previous = previous;
        _rates = rates;
      });
    } catch (_) {}
    // The statistics change slower than the open connections.
    if (_window != _Window.live && _statsSupported && tick % 3 == 0) await _refreshStats();
  }

  Future<void> _refreshStats() async {
    try {
      final stats = await _mac.client.stats(window: _window.minutes);
      if (mounted) setState(() => _stats = stats);
    } catch (_) {
      if (mounted) setState(() => _statsSupported = false);
    }
  }

  void _setWindow(_Window w) {
    setState(() {
      _windowPicked = true;
      _window = w;
      _stats = null;
      if (w == _Window.live && _sort == TrafficSort.last) _sort = TrafficSort.rate;
      if (w != _Window.live && _sort == TrafficSort.rate) _sort = TrafficSort.received;
    });
    if (w != _Window.live && _statsSupported) _refreshStats();
  }

  /// Clears in the helper too, or the closed ones come back the next time
  /// the list is read from the start, and the totals never reset.
  Future<void> _clear() async {
    try {
      await _mac.client.clearFlows();
      if (!mounted) return;
      setState(() {
        _closed = [];
        _stats = null;
      });
      if (_statsSupported) await _refreshStats();
    } catch (_) {
      if (!mounted) return;
      setState(() => _closed = []);
      showToast(context, 'Cleared here only. Update the helper to clear it for good.', warning: true);
    }
  }

  void _setQuery(TrafficQuery q, {bool editText = true}) {
    setState(() {
      _query = q;
      _selected = null;
    });
    if (editText && _queryCtrl.text != q.text) _queryCtrl.text = q.text;
  }

  String _routeName(String? id) {
    if (id == null || id.isEmpty) return '';
    final s = _mac.daemonStatus.value?.route(id);
    return s == null || s.name.isEmpty ? id : s.name;
  }

  /// What a value is called on screen.
  String _display(TrafficDim dim, String value) => switch (dim) {
        TrafficDim.route => value.isEmpty ? 'no route' : _routeName(value),
        TrafficDim.rule => value.isEmpty ? 'default' : _ruleNames[value] ?? value,
        TrafficDim.action => switch (value) {
            'route' => 'through a route',
            'direct' => 'direct',
            'block' => 'blocked',
            'system' => 'left to macOS',
            '' => 'undecided',
            _ => value,
          },
        TrafficDim.port => value == '0' ? '—' : value,
        _ => value.isEmpty ? '—' : value,
      };

  /// The rows the window covers, before the query.
  List<TrafficRow> get _source {
    TrafficRow live(FlowRecord f) {
      final r = _rates[f.id];
      return TrafficRow.fromFlow(f, rateUp: r?.$1 ?? 0, rateDown: r?.$2 ?? 0);
    }

    if (_window == _Window.live) return [for (final f in _active) live(f)];
    final stats = _stats;
    if (stats != null) return [for (final r in stats.rows) TrafficRow.fromStat(r)];
    // An older helper: what the recent connections add up to.
    final from = _window == _Window.all ? null : DateTime.now().subtract(Duration(minutes: _window.minutes));
    return [
      for (final f in _active) live(f),
      for (final f in _closed)
        if (from == null || (f.ended ?? f.started).isAfter(from)) TrafficRow.fromFlow(f),
    ];
  }

  bool _onPath(TrafficRow r, List<(TrafficDim, String)> path) => path.every((p) => r.value(p.$1) == p.$2);

  /// The table's lines: groups of the first dimension, and the children of
  /// those expanded, in order.
  List<TrafficGroup> _lines(List<TrafficRow> rows) {
    final out = <TrafficGroup>[];
    void add(List<TrafficRow> rows, int level, List<(TrafficDim, String)> parent) {
      for (final g in const GroupTraffic()(rows, _chain[level], sort: _sort, parent: parent)) {
        out.add(g);
        if (level + 1 < _chain.length && _expanded.contains(_pathKey(g.path))) {
          add(g.rows, level + 1, g.path);
        }
      }
    }

    if (_chain.isNotEmpty) add(rows, 0, const []);
    return out;
  }

  static String _pathKey(List<(TrafficDim, String)> path) => path.map((p) => '${p.$1.key}=${p.$2}').join('|');

  Future<void> _export(List<TrafficRow> rows) async {
    String csvCell(Object? v) {
      final s = '${v ?? ''}';
      return s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    }

    final header = ['app', 'site', 'host', 'port', 'protocol', 'action', 'route', 'rule', 'matched', 'connections', 'open', 'errors', 'upload', 'download', 'last', 'error_reasons'];
    List<Object?> line(TrafficRow r) => [
          r.app, r.site, r.host, r.port, r.network, r.action, _routeName(r.route), _display(TrafficDim.rule, r.ruleId ?? ''),
          r.matched, r.conns, r.open, r.errors, r.upload, r.download, r.last.toIso8601String(),
          r.reasons.map((e) => '${e.error} ×${e.count}').join('; '),
        ];
    final stamp = DateTime.now().toIso8601String().substring(0, 16).replaceAll(':', '-');
    await showActionSheet(context, title: 'Export ${rows.length} rows', actions: [
      SheetAction('CSV', () => exportText(context,
          fileName: 'vzhukh-traffic-$stamp.csv',
          text: [header, ...rows.map(line)].map((l) => l.map(csvCell).join(',')).join('\n')),
          icon: Icons.table_chart_outlined),
      SheetAction('JSON', () => exportText(context,
          fileName: 'vzhukh-traffic-$stamp.json',
          text: const JsonEncoder.withIndent('  ').convert([
            for (final r in rows) {for (final (i, h) in header.indexed) h: line(r)[i]},
          ])),
          icon: Icons.data_object),
    ]);
  }

  Future<void> _editChain(int level) => showActionSheet(
        context,
        title: level < _chain.length ? 'Group level ${level + 1} by' : 'Then group by',
        actions: [
          for (final d in TrafficDim.values)
            if (!_chain.contains(d) || (level < _chain.length && _chain[level] == d))
              SheetAction(d.label, () => setState(() {
                    level < _chain.length ? _chain[level] = d : _chain.add(d);
                    _expanded.clear();
                  }),
                  checked: level < _chain.length && _chain[level] == d),
          if (level < _chain.length && _chain.length > 1)
            SheetAction('Remove this level', () => setState(() {
                  _chain.removeAt(level);
                  _expanded.clear();
                }),
                icon: Icons.close, destructive: true),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = _window == _Window.live;
    final rows = [
      for (final r in _source)
        if (_query.matches(r, names: _display)) r,
    ];
    final lines = _lines(rows);
    final selected = _selected;
    final selectedRows = selected == null ? rows : [for (final r in rows) if (_onPath(r, selected)) r];
    final totals = TrafficTotals.of(rows);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Traffic'),
        actions: [
          if (_recording != null)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: _RecordButton(recording: _recording!, since: _recordingSince, onPressed: _toggleRecording),
            ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export what is shown',
            onPressed: rows.isEmpty ? null : () => _export(rows),
          ),
          IconButton(
            icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
            tooltip: _paused ? 'Resume' : 'Pause',
            onPressed: () => setState(() => _paused = !_paused),
          ),
          IconButton(icon: const Icon(Icons.clear_all), tooltip: 'Clear', onPressed: _clear),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HelperCard(mac: _mac, routeName: _routeName),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryCtrl,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'app:waterfox  site:youtube.com  -action:route  port:443  err',
                    ),
                    onChanged: (v) => _setQuery(TrafficQuery.parse(v), editText: false),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                SegmentedButton<_Window>(
                  showSelectedIcon: false,
                  segments: [for (final w in _Window.values) ButtonSegment(value: w, label: Text(w.label))],
                  selected: {_window},
                  onSelectionChanged: (s) => _setWindow(s.first),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
            child: Row(
              children: [
                for (final (label, q) in _presets)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: ChoiceChip(
                      label: Text(label),
                      visualDensity: VisualDensity.compact,
                      selected: _query.text.trim() == q,
                      onSelected: (_) => _setQuery(TrafficQuery.parse(q)),
                    ),
                  ),
                const Spacer(),
                Text(
                  '${totals.conns} conn · ${totals.open} open · ↑ ${formatBytes(totals.upload)} ↓ ${formatBytes(totals.download)}'
                  '${live ? ' · ${formatRate(totals.rate)}' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (!live && _stats != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
              child: TrafficChart(points: _stats!.timeline),
            ),
          if (!live && !_statsSupported)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
              child: Text(
                'This helper keeps only the last ${_closed.length} connections. Update it for an hour of history.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).warning),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          const Divider(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 220,
                  child: TrafficFacets(
                    rows: rows,
                    query: _query,
                    display: _display,
                    onToggle: (d, v) => _setQuery(_query.toggle(d, v)),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ChainBar(chain: _chain, onEdit: _editChain),
                      TrafficTableHeader(
                        title: _chain.map((d) => d.label).join(' › '),
                        sort: _sort,
                        live: live,
                        onSort: (s) => setState(() => _sort = s),
                      ),
                      const Divider(),
                      Expanded(
                        child: lines.isEmpty
                            ? (!live && _recording == false && _query.isEmpty
                                ? Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const EmptyState(
                                        icon: Icons.fiber_manual_record_outlined,
                                        title: 'Not recording',
                                        message: 'Open connections are always listed under "Open now". '
                                            'Record keeps the closed ones and an hour of totals, '
                                            'until you stop and clear.',
                                      ),
                                      FilledButton.icon(
                                        onPressed: _toggleRecording,
                                        icon: const Icon(Icons.fiber_manual_record),
                                        label: const Text('Record'),
                                      ),
                                    ],
                                  )
                                : EmptyState(
                                    icon: Icons.swap_vert,
                                    title: _query.isEmpty ? 'No traffic yet' : 'Nothing matches',
                                    message: _query.isEmpty ? null : 'Change the filter or the time window.',
                                  ))
                            : ListView.builder(
                                itemCount: lines.length,
                                itemExtent: 28,
                                itemBuilder: (_, i) {
                                  final g = lines[i];
                                  final key = _pathKey(g.path);
                                  return TrafficGroupLine(
                                    group: g,
                                    label: _display(g.dim, g.value),
                                    live: live,
                                    expandable: g.depth + 1 < _chain.length,
                                    expanded: _expanded.contains(key),
                                    selected: selected != null && _pathKey(selected) == key,
                                    onTap: () => setState(() => _selected = selected != null && _pathKey(selected) == key ? null : g.path),
                                    onToggle: () => setState(() => _expanded.contains(key) ? _expanded.remove(key) : _expanded.add(key)),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 340,
                  child: _Details(
                    path: selected,
                    rows: selectedRows,
                    flows: [
                      for (final f in [..._active, ..._closed])
                        if (selected == null || _onPath(TrafficRow.fromFlow(f), selected)) f,
                    ],
                    display: _display,
                    onFlow: _showFlow,
                    onMakeRule: widget.onMakeRule,
                    onFilter: (d, v) => _setQuery(_query.toggle(d, v)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showFlow(FlowRecord f) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: AppSpacing.lg),
            child: _FlowDetails(
              flow: f,
              routeName: _routeName(f.route),
              ruleName: f.ruleId == null ? null : _ruleNames[f.ruleId],
              onMakeRule: (draft) {
                Navigator.pop(ctx);
                widget.onMakeRule(draft);
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Record / Stop, with how long it has been recording.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.recording, required this.since, required this.onPressed});

  final bool recording;
  final DateTime? since;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final danger = AppColors.of(context).danger;
    if (!recording) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(Icons.fiber_manual_record, size: 14, color: danger),
        label: const Text('Record'),
      );
    }
    final s = since;
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(Icons.stop, size: 16, color: danger),
      label: Text(s == null ? 'Stop' : 'Stop · ${formatDuration(DateTime.now().difference(s))}'),
    );
  }
}

/// The grouping levels as chips: a click changes one, + adds one.
class _ChainBar extends StatelessWidget {
  const _ChainBar({required this.chain, required this.onEdit});

  final List<TrafficDim> chain;
  final void Function(int level) onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
      child: Row(
        children: [
          Text('Group by', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: AppSpacing.sm),
          for (final (i, d) in chain.indexed) ...[
            if (i > 0) Icon(Icons.chevron_right, size: 16, color: theme.colorScheme.onSurfaceVariant),
            ActionChip(label: Text(d.label), visualDensity: VisualDensity.compact, onPressed: () => onEdit(i)),
          ],
          if (chain.length < 4)
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              tooltip: 'Add a level',
              visualDensity: VisualDensity.compact,
              onPressed: () => onEdit(chain.length),
            ),
        ],
      ),
    );
  }
}

/// Right of the table: everything about the selected line, or about all
/// that is shown when none is selected.
class _Details extends StatelessWidget {
  const _Details({
    required this.path,
    required this.rows,
    required this.flows,
    required this.display,
    required this.onFlow,
    required this.onMakeRule,
    required this.onFilter,
  });

  final List<(TrafficDim, String)>? path;
  final List<TrafficRow> rows;
  final List<FlowRecord> flows;
  final String Function(TrafficDim, String) display;
  final ValueChanged<FlowRecord> onFlow;
  final void Function(RoutingRule) onMakeRule;
  final void Function(TrafficDim, String) onFilter;

  static const _breakdown = [
    TrafficDim.app,
    TrafficDim.site,
    TrafficDim.host,
    TrafficDim.port,
    TrafficDim.action,
    TrafficDim.route,
    TrafficDim.rule,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final path = this.path;
    final t = TrafficTotals.of(rows);
    final onPath = {for (final p in path ?? const <(TrafficDim, String)>[]) p.$1};

    final reasons = <String, int>{};
    final matched = <String, int>{};
    for (final r in rows) {
      for (final e in r.reasons) {
        reasons[e.error] = (reasons[e.error] ?? 0) + e.count;
      }
      if (r.matched != null) matched[r.matched!] = (matched[r.matched!] ?? 0) + r.conns;
    }
    List<MapEntry<String, int>> top(Map<String, int> m) =>
        (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(6).toList();

    final app = rows.where((r) => r.appPath != null).firstOrNull;
    final appName = path?.where((p) => p.$1 == TrafficDim.app).firstOrNull?.$2;
    final domain = path?.where((p) => p.$1 == TrafficDim.host || p.$1 == TrafficDim.site).lastOrNull?.$2;
    RuleAction opposite() => rows.every((r) => r.action == 'direct') ? RuleAction.connectedRoute : RuleAction.direct;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text(
          path == null ? 'Everything shown' : path.map((p) => display(p.$1, p.$2)).join(' › '),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpacing.md),
        TrafficSection(title: 'Totals', children: [
          TrafficKeyValue('Connections', '${t.conns}'),
          TrafficKeyValue('Open now', '${t.open}'),
          TrafficKeyValue('Errors', '${t.errors}', color: t.errors > 0 ? colors.danger : null),
          TrafficKeyValue('Sent', formatBytes(t.upload)),
          TrafficKeyValue('Received', formatBytes(t.download)),
          if (t.rate >= 1) TrafficKeyValue('Now', formatRate(t.rate)),
          TrafficKeyValue('Last seen', formatAgo(t.last)),
        ]),
        if (appName != null || domain != null)
          TrafficSection(title: 'Make a rule', children: [
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (appName != null)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.apps, size: 18),
                    label: Text('For $appName'),
                    onPressed: () => onMakeRule(RoutingRule(
                      id: newRuleId(),
                      name: appName,
                      apps: [app?.appPath ?? appName],
                      action: opposite(),
                    )),
                  ),
                if (domain != null)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.language, size: 18),
                    label: Text('For ${siteOf(domain)}'),
                    onPressed: () => onMakeRule(RoutingRule(
                      id: newRuleId(),
                      name: siteOf(domain),
                      domains: [siteOf(domain)],
                      action: opposite(),
                    )),
                  ),
              ],
            ),
          ]),
        if (matched.isNotEmpty)
          TrafficSection(title: 'Rules matched on', children: [
            for (final e in top(matched)) TrafficKeyValue(e.key, '${e.value}'),
          ]),
        if (reasons.isNotEmpty)
          TrafficSection(title: 'Errors', children: [
            for (final e in top(reasons)) TrafficKeyValue(e.key, '×${e.value}', color: colors.danger),
          ]),
        for (final dim in _breakdown)
          if (!onPath.contains(dim))
            if (const GroupTraffic()(rows, dim) case final groups when groups.length > 1 || (groups.length == 1 && path != null))
              TrafficSection(title: dim.label, children: [
                for (final g in groups.take(5))
                  TrafficKeyValue(
                    display(dim, g.value),
                    formatBytes(g.totals.bytes),
                    onTap: () => onFilter(dim, dim == TrafficDim.route || dim == TrafficDim.rule ? display(dim, g.value) : g.value),
                  ),
                if (groups.length > 5)
                  Text('and ${groups.length - 5} more', style: theme.textTheme.bodySmall?.copyWith(color: colors.muted)),
              ]),
        TrafficSection(title: 'Recent connections (${flows.length})', children: [
          for (final f in flows.take(40))
            InkWell(
              onTap: () => onFlow(f),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(actionStyle(context, f.action).icon, size: 12, color: actionStyle(context, f.action).color),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        '${f.owner} → ${f.target}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: f.error != null ? colors.danger : null),
                      ),
                    ),
                    Text(f.open ? 'open' : formatAgo(f.ended ?? f.started),
                        style: theme.textTheme.bodySmall?.copyWith(color: f.open ? colors.success : colors.muted)),
                  ],
                ),
              ),
            ),
          if (flows.isEmpty)
            Text('None among the last ones kept', style: theme.textTheme.bodySmall?.copyWith(color: colors.muted)),
        ]),
      ],
    );
  }
}

class _FlowDetails extends StatelessWidget {
  final FlowRecord flow;
  final String routeName;
  final String? ruleName;
  final void Function(RoutingRule) onMakeRule;

  const _FlowDetails({required this.flow, required this.routeName, required this.ruleName, required this.onMakeRule});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final rows = <(String, String?)>[
      ('App', flow.app),
      ('Executable', flow.exePath),
      ('PID', flow.pid?.toString()),
      ('Domain', flow.domain == null ? null : '${flow.domain}  (from ${flow.domainSource})'),
      ('App connected to', flow.destination),
      ('vzhukh opened', flow.dialed),
      ('Decision', switch (flow.action) {
        'route' => 'through route "$routeName"',
        'direct' => 'directly, past the tunnel',
        'block' => 'blocked',
        'system' => 'left to macOS (another VPN)',
        _ => flow.action,
      }),
      ('Because of', flow.ruleId == null
          ? 'no rule matched: default'
          : 'rule "${ruleName ?? flow.ruleId}"${flow.matched == null ? '' : ': ${flow.matched}'}'),
      ('Sent / received', '${formatBytes(flow.upload)} / ${formatBytes(flow.download)}'),
      ('Started', flow.started.toLocal().toString()),
      ('Lasted', formatDuration(flow.duration) + (flow.open ? ' (open)' : '')),
      ('Error', flow.error),
    ];
    final appTarget = flow.appPath ?? flow.exePath;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in rows)
            if (value != null && value.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 150, child: Text(label, style: TextStyle(color: muted))),
                    Expanded(child: SelectableText(value)),
                  ],
                ),
              ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              if (appTarget != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.apps),
                  label: Text('Rule for ${flow.owner}'),
                  onPressed: () => onMakeRule(RoutingRule(
                    id: newRuleId(),
                    name: flow.owner,
                    apps: [appTarget],
                    action: flow.action == 'direct' ? RuleAction.connectedRoute : RuleAction.direct,
                  )),
                ),
              if (flow.domain != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.language),
                  label: Text('Rule for ${siteOf(flow.domain!)}'),
                  onPressed: () => onMakeRule(RoutingRule(
                    id: newRuleId(),
                    name: siteOf(flow.domain!),
                    domains: [siteOf(flow.domain!)],
                    action: flow.action == 'direct' ? RuleAction.connectedRoute : RuleAction.direct,
                  )),
                ),
            ],
          ),
        ],
      ),
    );
  }

}

/// The helper's state, its routes, and install/update/uninstall.
class _HelperCard extends StatefulWidget {
  final MacDaemonBackend mac;
  final String Function(String?) routeName;

  const _HelperCard({required this.mac, required this.routeName});

  @override
  State<_HelperCard> createState() => _HelperCardState();
}

class _HelperCardState extends State<_HelperCard> {
  String? _bundledVersion;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _readBundledVersion();
  }

  Future<void> _readBundledVersion() async {
    final binary = DaemonInstallation.bundledBinary();
    if (!binary.existsSync()) return;
    final result = await Process.run(binary.path, ['-version']);
    if (mounted && result.exitCode == 0) {
      setState(() => _bundledVersion = '${result.stdout}'.trim());
    }
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showToast(context, done);
    } on InstallCancelled {
      // Nothing to say.
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return ValueListenableBuilder<DaemonStatus?>(
      valueListenable: widget.mac.daemonStatus,
      builder: (context, status, _) {
        final installed = DaemonInstallation.isInstalled;
        final outdated = status != null && _bundledVersion != null && status.version != _bundledVersion;

        final Widget body;
        if (status == null) {
          body = Text(
            installed
                ? 'The network helper is installed but not answering. '
                    'Its log is ${DaemonInstallation.logPath}.'
                : 'The network helper is not installed. Without it vzhukh only '
                    'runs a SOCKS proxy on 127.0.0.1:2080, and other apps reach '
                    'the tunnel only if pointed at it.',
          );
        } else {
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(switch (status.state) {
                DaemonState.running =>
                  'Tunnel ${status.tunnelInterface ?? ''} is up; past it, traffic leaves through ${status.physicalInterface ?? '?'}. '
                      'DNS for direct connections: ${status.upstreamDns.take(3).join(', ')}.',
                DaemonState.idle => 'Helper v${status.version} is idle. Connect a route or server to start.',
                DaemonState.error => 'Helper failed: ${status.error}',
              }),
              for (final r in status.routes)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Row(
                    children: [
                      Icon(Icons.circle, size: 10, color: switch (r.state) {
                        RouteState.up => colors.success,
                        RouteState.connecting => colors.warning,
                        RouteState.down => colors.danger,
                      }),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          '${widget.routeName(r.id)} (${r.server}, ${r.hops} hop${r.hops == 1 ? '' : 's'}): ${r.state.name}'
                          '${r.error != null && r.state != RouteState.up ? ' — ${r.error}' : ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        }

        return Card(
          margin: const EdgeInsets.all(AppSpacing.sm),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: body),
                const SizedBox(width: AppSpacing.md),
                if (_busy)
                  const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                else if (!installed || status == null || outdated)
                  FilledButton(
                    onPressed: () => _run(() => const InstallDaemon()(), 'Helper installed'),
                    child: Text(!installed ? 'Install helper' : outdated ? 'Update helper' : 'Reinstall'),
                  ),
                if (installed && !_busy)
                  ActionSheetButton(
                    title: 'Helper',
                    actions: () => [
                      SheetAction(
                        'Uninstall helper',
                        () => _run(() => const UninstallDaemon()(), 'Helper removed'),
                        icon: Icons.delete_outline,
                        destructive: true,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
