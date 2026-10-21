import 'dart:math';

import 'package:flutter/material.dart';

import '../../daemon/list_installed_apps.dart';
import '../../models/routing_rule.dart';
import '../../models/tunnel_route.dart';
import '../action_sheet.dart';
import '../common/widgets.dart';
import '../theme/app_theme.dart';

String newRuleId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 20).toRadixString(36)}';

/// Edits one rule. Returns the edited rule, or null on cancel.
class RuleEditScreen extends StatefulWidget {
  final RoutingRule? existing;

  /// Prefilled rule for "make a rule from this connection".
  final RoutingRule? draft;
  final List<TunnelRoute> routes;

  const RuleEditScreen({
    super.key,
    this.existing,
    this.draft,
    required this.routes,
  });

  @override
  State<RuleEditScreen> createState() => _RuleEditScreenState();
}

class _RuleEditScreenState extends State<RuleEditScreen> {
  late final RoutingRule _initial =
      widget.existing ?? widget.draft ?? RoutingRule(id: newRuleId(), name: '', action: RuleAction.direct);

  late final _name = TextEditingController(text: _initial.name);
  late final _domains = TextEditingController(text: _initial.domains.join('\n'));
  late final _cidrs = TextEditingController(text: _initial.cidrs.join('\n'));
  late final _ports = TextEditingController(text: _initial.ports.join(', '));
  late List<String> _apps = [..._initial.apps];
  late RuleAction _action = _initial.action;
  late String? _routeId = _initial.routeId;
  late bool _enabled = _initial.enabled;

  @override
  void dispose() {
    _name.dispose();
    _domains.dispose();
    _cidrs.dispose();
    _ports.dispose();
    super.dispose();
  }

  List<String> _lines(String text) => text
      .split(RegExp(r'[\n,]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  String? _validate() {
    final ip = RegExp(r'^[0-9a-fA-F:.]+(/\d{1,3})?$');
    for (final c in _lines(_cidrs.text)) {
      if (!ip.hasMatch(c)) return 'Not an address or CIDR: $c';
    }
    final port = RegExp(r'^\d{1,5}(-\d{1,5})?$');
    for (final p in _lines(_ports.text)) {
      if (!port.hasMatch(p)) return 'Not a port or range: $p';
    }
    if (_action == RuleAction.route && _routeId == null) {
      return 'Pick the route to send matches through';
    }
    return null;
  }

  void _save() {
    final problem = _validate();
    if (problem != null) {
      showToast(context, problem);
      return;
    }
    final domains = _lines(_domains.text);
    final name = _name.text.trim().isNotEmpty
        ? _name.text.trim()
        : [
            ..._apps.map((a) => a.split('/').last.replaceAll('.app', '')),
            ...domains,
          ].take(2).join(', ');
    Navigator.pop(
      context,
      RoutingRule(
        id: _initial.id,
        name: name.isEmpty ? 'Everything' : name,
        apps: _apps,
        domains: domains,
        cidrs: _lines(_cidrs.text),
        ports: _lines(_ports.text),
        action: _action,
        routeId: _action == RuleAction.route ? _routeId : null,
        enabled: _enabled,
      ),
    );
  }

  Future<void> _pickApps() async {
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _AppPickerDialog(selected: _apps),
    );
    if (picked != null) setState(() => _apps = picked);
  }

  Future<void> _addAppByName() async {
    final ctrl = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a program'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'curl  or  /usr/bin/ssh',
            helperText: 'A name matches an app or executable;\na path starting with / matches everything under it.',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Add')),
        ],
      ),
    );
    final v = value?.trim();
    if (v != null && v.isNotEmpty && !_apps.contains(v)) {
      setState(() => _apps = [..._apps, v]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New rule' : 'Edit rule'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'Named after what it matches if left empty'),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Send matching connections', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          _ActionPicker(
            action: _action,
            routeId: _routeId,
            routes: widget.routes,
            onChanged: (action, routeId) => setState(() {
              _action = action;
              _routeId = routeId;
            }),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Match', style: Theme.of(context).textTheme.titleSmall),
          Text(
            'Apps, destination and ports each have to match when filled, and '
            'any entry within one may. Domains and addresses are one '
            'destination: either matches. A rule with nothing filled matches '
            'everything.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Text('Apps', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              TextButton.icon(onPressed: _pickApps, icon: const Icon(Icons.apps), label: const Text('Choose')),
              TextButton.icon(onPressed: _addAppByName, icon: const Icon(Icons.terminal), label: const Text('Program')),
            ],
          ),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              if (_apps.isEmpty)
                Text('Any app', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              for (final app in _apps)
                InputChip(
                  label: Text(app.startsWith('/') ? app.split('/').last : app),
                  tooltip: app,
                  onDeleted: () => setState(() => _apps = [..._apps]..remove(app)),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _domains,
            minLines: 2,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Domains',
              hintText: 'youtube.com\ngooglevideo.com',
              helperText: 'One per line. Each covers its subdomains too.',
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _cidrs,
            minLines: 1,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: 'Addresses',
              hintText: '10.0.0.0/8',
              helperText: _action == RuleAction.system
                  ? 'Or the domains above. With no apps and ports, these never '
                      'enter the tunnel at all: right for a VPN\'s gateway.'
                  : 'Or the domains above. Seen only for connections made to '
                      'an address, not a name.',
              helperMaxLines: 2,
            ),
          ),

          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _ports,
            decoration: const InputDecoration(
              labelText: 'Ports',
              hintText: '443, 8000-8999',
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
        ],
      ),
    );
  }
}

class _ActionPicker extends StatelessWidget {
  final RuleAction action;
  final String? routeId;
  final List<TunnelRoute> routes;
  final void Function(RuleAction, String?) onChanged;

  const _ActionPicker({
    required this.action,
    required this.routeId,
    required this.routes,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = action == RuleAction.route && !routes.any((r) => r.id == routeId)
        ? RuleAction.connectedRoute
        : action;
    bool isCurrent(RuleAction a, [String? id]) => current == a && (a != RuleAction.route || routeId == id);
    final options = [
      SheetAction('Through the connected route', () => onChanged(RuleAction.connectedRoute, null),
          icon: Icons.vpn_lock, checked: isCurrent(RuleAction.connectedRoute)),
      for (final r in routes)
        SheetAction('Through "${r.label}"', () => onChanged(RuleAction.route, r.id),
            icon: Icons.route_outlined, checked: isCurrent(RuleAction.route, r.id)),
      SheetAction('Directly, past the tunnel', () => onChanged(RuleAction.direct, null),
          icon: Icons.arrow_outward, checked: isCurrent(RuleAction.direct)),
      SheetAction('Nowhere: block', () => onChanged(RuleAction.block, null),
          icon: Icons.block, checked: isCurrent(RuleAction.block)),
      SheetAction('Leave to macOS', () => onChanged(RuleAction.system, null),
          icon: Icons.business, subtitle: 'Corporate VPN and the like', checked: isCurrent(RuleAction.system)),
    ];
    final picked = options.firstWhere((o) => o.checked);
    // A field that opens the choice in a dialog, not a drop-down list.
    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
      onTap: () => showActionSheet(context, title: 'Send matching connections', actions: options),
      child: InputDecorator(
        decoration: const InputDecoration(suffixIcon: Icon(Icons.unfold_more)),
        child: Row(
          children: [
            Icon(picked.icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.sm),
            Flexible(child: Text(picked.label, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }
}

class _AppPickerDialog extends StatefulWidget {
  final List<String> selected;
  const _AppPickerDialog({required this.selected});

  @override
  State<_AppPickerDialog> createState() => _AppPickerDialogState();
}

class _AppPickerDialogState extends State<_AppPickerDialog> {
  late final Set<String> _selected = {...widget.selected};
  List<InstalledApp> _apps = [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    const ListInstalledApps()().then((apps) {
      if (mounted) setState(() => _apps = apps);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = _apps
        .where((a) => _query.isEmpty || a.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return AlertDialog(
      title: const Text('Apps'),
      content: SizedBox(
        width: 420,
        height: 480,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search'),
              onChanged: (v) => setState(() => _query = v),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (_, i) {
                  final app = shown[i];
                  return CheckboxListTile(
                    dense: true,
                    title: Text(app.name),
                    subtitle: Text(app.path, style: Theme.of(context).textTheme.bodySmall),
                    value: _selected.contains(app.path),
                    onChanged: (v) => setState(() {
                      v == true ? _selected.add(app.path) : _selected.remove(app.path);
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(context, [
            ...widget.selected.where((a) => !a.endsWith('.app')),
            ..._selected.where((a) => a.endsWith('.app')),
          ]),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
