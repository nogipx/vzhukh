import 'package:flutter/material.dart';

import '../../models/routing_rule.dart';
import '../../models/tunnel_route.dart';
import '../../storage/route_repository.dart';
import '../../models/rule_set.dart';
import '../../storage/routing_rules_repository.dart';
import '../../storage/rule_set_repository.dart';
import '../../storage/set_archive.dart';
import '../../sync/received_items.dart';
import '../../vpn/vpn_controller.dart';
import '../lan_sync_screen.dart';
import '../set_transfer.dart';
import '../common/widgets.dart';
import '../theme/app_theme.dart';
import '../../sync/sync_signal.dart';
import 'rule_edit_screen.dart';
import '../action_sheet.dart';

/// The ordered rule list. Connections are matched top to bottom; the first
/// rule that matches decides, and the default below decides the rest.
class RulesScreen extends StatefulWidget {
  final VpnController vpn;
  const RulesScreen({super.key, required this.vpn});

  @override
  State<RulesScreen> createState() => RulesScreenState();
}

class RulesScreenState extends State<RulesScreen> {
  final _repo = RoutingRulesRepository();
  final _sets = RuleSetRepository();
  final _routeRepo = RouteRepository();
  RoutingRules _rules = const RoutingRules();
  List<TunnelRoute> _routes = [];
  List<RuleSet> _own = [];
  RuleSet? _active;

  /// Whether the active set is this device's own. Another device's set is
  /// shown as it is and cannot be edited here.
  bool _activeOwn = true;

  @override
  void initState() {
    super.initState();
    _load();
    SyncSignal.instance.remote.addListener(_load);
  }

  @override
  void dispose() {
    SyncSignal.instance.remote.removeListener(_load);
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final own = await _sets.getAll();
    final active = await _sets.active();
    var rules = active.set?.rules ?? const RoutingRules();
    if (active.own && active.set != null && rules.bypass.isNotEmpty) {
      // The separate "never through vzhukh" list became the addresses of a
      // "leave to macOS" rule, which the helper keeps out of the tunnel.
      rules = _foldBypass(rules);
      await _repo.save(rules);
    }
    final routes = [
      ...await _routeRepo.getRoutes(),
      for (final r in ReceivedItems.instance.routes) r.value,
    ];
    if (mounted) {
      setState(() {
        _rules = rules;
        _routes = routes;
        _own = own;
        _active = active.set;
        _activeOwn = active.own;
      });
    }
  }

  // ---- Sets ----

  Future<void> _select(String id) async {
    await _sets.setActive(id);
    await _load();
    await _apply();
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Work, Home, Travel…'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _newSet() async {
    final name = await _askName('New rule set');
    if (name == null) return;
    final set = RuleSet(id: RuleSetRepository.newId(), name: name, rules: const RoutingRules());
    await _sets.save(set);
    await _select(set.id);
  }

  Future<void> _renameSet() async {
    final set = _active;
    if (set == null || !_activeOwn) return;
    final name = await _askName('Rename rule set', initial: set.name);
    if (name == null) return;
    await _sets.save(set.copyWith(name: name));
    await _load();
  }

  Future<void> _deleteSet() async {
    final set = _active;
    if (set == null || !_activeOwn) return;
    final ok = await confirmDestructive(
      context,
      title: 'Delete "${set.name}"?',
      message: 'Devices it is shared with lose it too.',
    );
    if (!ok) return;
    await _sets.delete(set.id);
    await _load();
    await _apply();
  }

  Future<void> _exportSet() async {
    final set = _active;
    if (set == null || !_activeOwn) return;
    await exportText(context, fileName: SetArchive.ruleSetFile(set), text: SetArchive.encodeRuleSet(set));
  }

  Future<void> _importSet() async {
    final text = await importText(context);
    if (text == null) return;
    try {
      final set = SetArchive.decode(text, id: RuleSetRepository.newId());
      if (set is! RuleSet) throw const FormatException('This is an app set, not a rule set');
      await _sets.save(set);
      await _select(set.id);
      if (mounted) showToast(context, 'Imported "${set.name}".');
    } on FormatException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  Future<void> _apply() async {
    try {
      await widget.vpn.applyRules();
    } catch (e) {
      if (mounted) showToast(context, 'Not applied: $e', warning: true);
    }
  }

  Widget _setSelector() {
    final received = [
      for (final r in ReceivedItems.instance.ruleSets)
        if (!_own.any((s) => s.id == r.value.id)) r,
    ];
    return ActionSheetButton(
      title: 'Rule sets',
      tooltip: 'Rule sets',
      actions: () => [
        for (final s in _own)
          SheetAction(s.name, () => _select(s.id), checked: s.id == _active?.id),
        if (received.isNotEmpty) const SheetAction.divider(),
        for (final r in received)
          SheetAction(r.value.name, () => _select(r.value.id),
              subtitle: 'from ${r.ownerName}', checked: r.value.id == _active?.id),
        const SheetAction.divider(),
        SheetAction('New rule set…', _newSet, icon: Icons.add),
        SheetAction('Import a rule set…', _importSet, icon: Icons.file_open_outlined),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_active?.name ?? 'Rules'),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }

  static RoutingRules _foldBypass(RoutingRules rules) {
    final list = [...rules.rules];
    final i = list.indexWhere((r) =>
        r.action == RuleAction.system && r.apps.isEmpty && r.ports.isEmpty);
    if (i >= 0) {
      final r = list[i];
      list[i] = r.copyWith(cidrs: {...r.cidrs, ...rules.bypass}.toList());
    } else {
      list.insert(
        0,
        RoutingRule(
          id: newRuleId(),
          name: 'Kept out of the tunnel',
          cidrs: rules.bypass,
          action: RuleAction.system,
        ),
      );
    }
    return rules.copyWith(rules: list, bypass: const []);
  }

  Future<void> _save(RoutingRules rules) async {
    if (!_activeOwn) return;
    setState(() => _rules = rules);
    await _repo.save(rules);
    try {
      await widget.vpn.applyRules();
    } catch (e) {
      if (mounted) showToast(context, 'Saved, but not applied: $e', warning: true);
    }
  }

  /// Opens the editor; with [draft], for a new rule prefilled from a
  /// connection.
  Future<void> edit({RoutingRule? existing, RoutingRule? draft}) async {
    final routes = await _routeRepo.getRoutes();
    if (!mounted) return;
    final result = await Navigator.push<RoutingRule>(
      context,
      MaterialPageRoute(
        builder: (_) => RuleEditScreen(existing: existing, draft: draft, routes: routes),
      ),
    );
    if (result == null) return;
    final rules = [..._rules.rules];
    final i = rules.indexWhere((r) => r.id == result.id);
    if (i >= 0) {
      rules[i] = result;
    } else {
      // New rules go first: a rule made for one app or site is more
      // specific than what is already there.
      rules.insert(0, result);
    }
    await _save(_rules.copyWith(rules: rules));
  }

  String _actionLabel(RoutingRule r) => switch (r.action) {
        RuleAction.connectedRoute => 'Tunnel',
        RuleAction.route =>
          _routes.where((x) => x.id == r.routeId).firstOrNull?.label ?? 'Missing route',
        RuleAction.direct => 'Direct',
        RuleAction.block => 'Block',
        RuleAction.system => 'macOS',
      };

  /// What a rule matches, short: the first few targets and how many more.
  String _summary(RoutingRule r) {
    final targets = [
      ...r.apps.map((a) => a.split('/').last.replaceAll('.app', '')),
      ...r.domains,
      ...r.cidrs,
    ];
    final ports = r.ports.isEmpty ? '' : '  ·  ports ${r.ports.join(', ')}';
    if (targets.isEmpty) return 'everything$ports';
    const shown = 3;
    final more = targets.length > shown ? '  +${targets.length - shown}' : '';
    return '${targets.take(shown).join(', ')}$more$ports';
  }

  // ---- Search and filter ----

  final _search = TextEditingController();
  RuleAction? _only;

  bool _matches(RoutingRule r) {
    if (_only != null) {
      final kind = r.action == RuleAction.route ? RuleAction.connectedRoute : r.action;
      if (kind != _only) return false;
    }
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [r.name, ...r.apps, ...r.domains, ...r.cidrs, ...r.ports]
        .any((t) => t.toLowerCase().contains(q));
  }

  bool get _filtering => _only != null || _search.text.trim().isNotEmpty;

  // ---- Row actions ----

  Future<void> _rowAction(RoutingRule r, String action) async {
    final list = [..._rules.rules];
    final i = list.indexWhere((x) => x.id == r.id);
    if (i < 0) return;
    switch (action) {
      case 'edit':
        await edit(existing: r);
      case 'top':
        list.insert(0, list.removeAt(i));
        await _save(_rules.copyWith(rules: list));
      case 'bottom':
        list.add(list.removeAt(i));
        await _save(_rules.copyWith(rules: list));
      case 'delete':
        final ok = await confirmDestructive(
          context,
          title: 'Delete "${r.name}"?',
          message: _summary(r),
        );
        if (ok) {
          list.removeAt(i);
          await _save(_rules.copyWith(rules: list));
        }
    }
  }

  Widget _row(RoutingRule r, {int? dragIndex}) {
    return ListTile(
      key: ValueKey(r.id),
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: dragIndex != null && _activeOwn
          ? ReorderableDragStartListener(index: dragIndex, child: const Icon(Icons.drag_indicator))
          : Icon(_activeOwn ? Icons.drag_indicator : Icons.lock_outline,
              color: Theme.of(context).disabledColor),
      title: Row(
        children: [
          Flexible(
            child: Text(
              r.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: r.enabled ? null : Theme.of(context).disabledColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _ActionBadge(action: r.action, label: _actionLabel(r), enabled: r.enabled),
        ],
      ),
      subtitle: Text(_summary(r), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: _activeOwn ? () => edit(existing: r) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: r.enabled,
            onChanged: !_activeOwn
                ? null
                : (v) {
                    final list = [..._rules.rules];
                    final i = list.indexWhere((x) => x.id == r.id);
                    list[i] = r.copyWith(enabled: v);
                    _save(_rules.copyWith(rules: list));
                  },
          ),
          if (_activeOwn)
            ActionSheetButton(
              actions: () => [
                SheetAction('Edit', () => _rowAction(r, 'edit'), icon: Icons.edit_outlined),
                SheetAction('Move to top', () => _rowAction(r, 'top'),
                    icon: Icons.vertical_align_top),
                SheetAction('Move to bottom', () => _rowAction(r, 'bottom'),
                    icon: Icons.vertical_align_bottom),
                const SheetAction.divider(),
                SheetAction('Delete', () => _rowAction(r, 'delete'),
                    icon: Icons.delete_outline, destructive: true),
              ],
            ),
        ],
      ),
    );
  }

  Widget _toolbar() {
    final theme = Theme.of(context);
    Widget chip(RuleAction? action, String label) => Padding(
          padding: const EdgeInsets.only(right: AppSpacing.xs),
          child: ChoiceChip(
            label: Text(label),
            selected: _only == action,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => setState(() => _only = action),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 260,
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'Search name, domain, app',
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(_search.clear),
                      ),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              chip(null, 'All'),
              chip(RuleAction.connectedRoute, 'Tunnel'),
              chip(RuleAction.direct, 'Direct'),
              chip(RuleAction.system, 'macOS'),
              chip(RuleAction.block, 'Block'),
            ],
          ),
          if (_filtering)
            Text(
              '${_rules.rules.where(_matches).length} of ${_rules.rules.length}',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rules = _rules.rules;
    final shown = rules.where(_matches).toList();
    return Scaffold(
      appBar: AppBar(
        title: _setSelector(),
        actions: [
          if (_active != null && _activeOwn)
            ActionSheetButton(
              tooltip: 'This rule set',
              title: _active!.name,
              actions: () => [
                SheetAction('Rename', _renameSet, icon: Icons.edit_outlined),
                SheetAction('Share with my devices',
                    () => showShareDialog(context, 'ruleset/${_active!.id}', '"${_active!.name}"'),
                    icon: Icons.devices),
                SheetAction('Export', _exportSet, icon: Icons.ios_share),
                SheetAction('Delete', _deleteSet, icon: Icons.delete_outline, destructive: true),
              ],
            ),
        ],
      ),
      floatingActionButton: _activeOwn
          ? FloatingActionButton(
              onPressed: () => edit(),
              child: const Icon(Icons.add),
            )
          : null,
      body: Column(
        children: [
          if (_active != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: _activeOwn
                  ? ShareStatusLabel('ruleset/${_active!.id}')
                  : ShareStatusLabel.received('ruleset/${_active!.id}'),
            ),
          _DefaultBar(
            value: _rules.defaultAction,
            enabled: _activeOwn,
            onChanged: (v) => _save(_rules.copyWith(defaultAction: v)),
          ),
          if (rules.isNotEmpty) _toolbar(),
          const Divider(height: 1),
          Expanded(
            child: rules.isEmpty
                ? const EmptyState(
                    icon: Icons.rule,
                    title: 'No rules yet',
                    message: 'Everything follows "Everything else" above.\n\n'
                        'Add one here, or from a connection on the Traffic tab.',
                  )
                : _filtering || !_activeOwn
                    // Order can only be changed on the whole list.
                    ? ListView(
                        padding: const EdgeInsets.only(bottom: 88),
                        children: [for (final r in shown) _row(r)],
                      )
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: rules.length,
                        onReorderItem: (from, to) {
                          final list = [...rules];
                          list.insert(to, list.removeAt(from));
                          _save(_rules.copyWith(rules: list));
                        },
                        itemBuilder: (_, i) => _row(rules[i], dragIndex: i),
                      ),
          ),
        ],
      ),
    );
  }
}

/// Where a rule sends what it matches, in a color of its own so the list
/// reads at a glance.
class _ActionBadge extends StatelessWidget {
  const _ActionBadge({required this.action, required this.label, required this.enabled});

  final RuleAction action;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final color = !enabled
        ? theme.disabledColor
        : switch (action) {
            RuleAction.connectedRoute || RuleAction.route => theme.colorScheme.primary,
            RuleAction.direct => colors.info,
            RuleAction.system => colors.warning,
            RuleAction.block => colors.danger,
          };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color)),
    );
  }
}

/// What happens to everything no rule matches: most connections, as a rule
/// set usually names a few sites and apps. One line above the list, always
/// in view, because a setting at the bottom was easy to miss and then
/// nothing seemed to follow the rules.
class _DefaultBar extends StatelessWidget {
  final DefaultAction value;
  final bool enabled;
  final ValueChanged<DefaultAction> onChanged;

  const _DefaultBar({required this.value, required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: Row(
        children: [
          Tooltip(
            message: 'Rules are checked top to bottom; whatever none of them matches goes here.',
            child: Text('Everything else', style: theme.textTheme.titleSmall),
          ),
          const SizedBox(width: AppSpacing.md),
          SegmentedButton<DefaultAction>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: DefaultAction.connectedRoute,
                icon: Icon(Icons.vpn_lock, size: 18),
                label: Text('Through the tunnel'),
              ),
              ButtonSegment(
                value: DefaultAction.direct,
                icon: Icon(Icons.arrow_outward, size: 18),
                label: Text('Directly'),
              ),
            ],
            selected: {value},
            onSelectionChanged: enabled ? (s) => onChanged(s.first) : null,
          ),
        ],
      ),
    );
  }
}
