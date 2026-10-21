import 'package:flutter/material.dart';

import '../../models/app_info.dart';
import '../../models/app_routing_config.dart';
import '../../models/app_set.dart';
import '../../storage/app_set_repository.dart';
import '../../sync/received_items.dart';
import '../../sync/sync_signal.dart';
import '../../vpn/list_android_apps.dart';
import '../action_sheet.dart';
import '../app_set_picker_screen.dart';
import '../theme/app_theme.dart';
import 'tv_actions.dart';
import 'tv_button.dart';
import 'tv_confirm_dialog.dart';

/// The app sets, on a TV. With [picking], OK on a set picks it and the
/// screen returns an [AppSetChoice]; without, OK edits its apps.
class TvAppSetScreen extends StatefulWidget {
  const TvAppSetScreen({super.key, this.selected, this.picking = true});

  final String? selected;
  final bool picking;

  @override
  State<TvAppSetScreen> createState() => _TvAppSetScreenState();
}

class _TvAppSetScreenState extends State<TvAppSetScreen> {
  final _repo = AppSetRepository();
  List<AppSet> _own = [];

  @override
  void initState() {
    super.initState();
    _load();
    SyncSignal.instance.remote.addListener(_load);
  }

  @override
  void dispose() {
    SyncSignal.instance.remote.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final own = await _repo.getAll();
    if (mounted) setState(() => _own = own);
  }

  void _pick(String? id) => Navigator.pop(context, AppSetChoice(id));

  Future<AppRoutingConfig?> _editApps(String name, AppRoutingConfig initial) =>
      Navigator.push<AppRoutingConfig>(
        context,
        MaterialPageRoute(builder: (_) => TvAppPickerScreen(title: name, initial: initial)),
      );

  Future<String?> _askName(String title, {String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Streaming, Everything but banks…'),
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

  Future<void> _new() async {
    final name = await _askName('New app set');
    if (name == null || !mounted) return;
    final config = await _editApps(name, const AppRoutingConfig.empty());
    if (config == null) return;
    final set = AppSet(id: AppSetRepository.newId(), name: name, config: config);
    await _repo.save(set);
    if (widget.picking) {
      _pick(set.id);
    } else {
      await _load();
    }
  }

  Future<void> _edit(AppSet set) async {
    final config = await _editApps(set.name, set.config);
    if (config != null) await _repo.save(set.copyWith(config: config));
    await _load();
  }

  Future<void> _more(AppSet set) => showTvActions(
        context,
        title: set.name,
        actions: [
          SheetAction('Edit apps', () => _edit(set), icon: Icons.apps),
          SheetAction('Rename', () async {
            final name = await _askName('Rename app set', initial: set.name);
            if (name != null) await _repo.save(set.copyWith(name: name));
            await _load();
          }, icon: Icons.edit_outlined),
          SheetAction('Delete', () async {
            final ok = await showTvConfirmDialog(
              context,
              title: 'Delete "${set.name}"?',
              message: 'Servers and routes that use it go back to all apps.',
              confirmLabel: 'Delete',
            );
            if (!ok) return;
            await _repo.delete(set.id);
            await _load();
          }, icon: Icons.delete_outline, destructive: true),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final received = [
      for (final r in ReceivedItems.instance.appSets)
        if (!_own.any((s) => s.id == r.value.id)) r,
    ];
    var first = true;
    bool autofocus() {
      final f = first;
      first = false;
      return f;
    }

    IconData mark(String? id) => !widget.picking
        ? Icons.apps
        : id == widget.selected
            ? Icons.radio_button_checked
            : Icons.radio_button_unchecked;

    return TvPage(
      title: widget.picking ? 'Apps through the tunnel' : 'App sets',
      subtitle: widget.picking ? 'Which apps of this TV use it' : 'Lists of apps a server or route can be limited to',
      action: TvButton(label: 'New set', icon: Icons.add, filled: false, compact: true, minWidth: 0, onPressed: _new),
      child: ListView(
        children: [
          if (widget.picking)
            _gap(TvRow(
              autofocus: autofocus(),
              icon: mark(null),
              iconColor: widget.selected == null ? Theme.of(context).colorScheme.primary : null,
              title: 'All apps',
              subtitle: 'Everything goes through the tunnel',
              onPressed: () => _pick(null),
            )),
          for (final s in _own)
            _gap(TvRowWithMore(
              onMore: () => _more(s),
              row: TvRow(
                autofocus: autofocus(),
                icon: mark(s.id),
                iconColor: widget.picking && s.id == widget.selected ? Theme.of(context).colorScheme.primary : null,
                title: s.name,
                subtitle: describeAppSet(s.config),
                onPressed: widget.picking ? () => _pick(s.id) : () => _edit(s),
              ),
            )),
          for (final r in received)
            _gap(TvRow(
              autofocus: autofocus(),
              icon: mark(r.value.id),
              iconColor: widget.picking && r.value.id == widget.selected ? Theme.of(context).colorScheme.primary : null,
              title: r.value.name,
              subtitle: '${describeAppSet(r.value.config)} · from ${r.ownerName}',
              enabled: widget.picking,
              onPressed: () => _pick(r.value.id),
            )),
        ],
      ),
    );
  }

  Widget _gap(Widget child) => Padding(padding: const EdgeInsets.only(bottom: AppSpacing.sm), child: child);
}

/// Which apps of this TV a set holds, and whether they are the only ones
/// through the tunnel or the ones left out. Back keeps the changes; the
/// screen returns the new [AppRoutingConfig].
class TvAppPickerScreen extends StatefulWidget {
  const TvAppPickerScreen({super.key, required this.title, required this.initial});

  final String title;
  final AppRoutingConfig initial;

  @override
  State<TvAppPickerScreen> createState() => _TvAppPickerScreenState();
}

class _TvAppPickerScreenState extends State<TvAppPickerScreen> {
  List<AppInfo>? _apps;
  late AppRoutingMode _mode = widget.initial.mode;
  late final Set<String> _selected = widget.initial.packages.toSet();

  @override
  void initState() {
    super.initState();
    const ListAndroidApps()().then((apps) {
      if (!mounted) return;
      apps.sort((a, b) {
        // What is checked first, then by name: on a remote, scrolling past
        // a hundred apps to find the three picked is slow.
        final picked = (_selected.contains(b.packageName) ? 1 : 0) - (_selected.contains(a.packageName) ? 1 : 0);
        return picked != 0 ? picked : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
      setState(() => _apps = apps);
    });
  }

  AppRoutingConfig get _config => AppRoutingConfig(mode: _mode, packages: _selected.toList());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apps = _apps;
    final only = _mode == AppRoutingMode.whitelist;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _config);
      },
      child: TvPage(
        title: widget.title,
        subtitle: '${_selected.length} checked',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TvRow(
              autofocus: true,
              icon: only ? Icons.filter_alt_outlined : Icons.filter_alt_off_outlined,
              title: only ? 'Only the checked apps use the tunnel' : 'All apps but the checked ones use the tunnel',
              subtitle: 'OK switches',
              onPressed: () => setState(
                  () => _mode = only ? AppRoutingMode.blacklist : AppRoutingMode.whitelist),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: apps == null
                  ? const Center(child: CircularProgressIndicator())
                  : apps.isEmpty
                      ? Center(
                          child: Text('No apps found', style: theme.textTheme.bodyLarge),
                        )
                      : ListView.builder(
                          itemCount: apps.length,
                          itemBuilder: (_, i) {
                            final app = apps[i];
                            final checked = _selected.contains(app.packageName);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                              child: TvRow(
                                title: app.label,
                                subtitle: app.packageName,
                                leading: app.icon == null
                                    ? null
                                    : Image.memory(app.icon!, width: 40, height: 40, gaplessPlayback: true),
                                trailing: Icon(
                                  checked ? Icons.check_box : Icons.check_box_outline_blank,
                                  color: checked ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                                ),
                                onPressed: () => setState(() {
                                  checked ? _selected.remove(app.packageName) : _selected.add(app.packageName);
                                }),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
