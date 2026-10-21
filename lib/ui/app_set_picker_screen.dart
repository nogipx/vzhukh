import 'package:flutter/material.dart';

import '../models/app_routing_config.dart';
import '../models/app_set.dart';
import '../storage/app_set_repository.dart';
import '../storage/set_archive.dart';
import '../sync/received_items.dart';
import '../sync/sync_signal.dart';
import 'app_picker_screen.dart';
import 'lan_sync_screen.dart';
import 'set_transfer.dart';
import 'action_sheet.dart';
import 'common/widgets.dart';

/// What the picker returns: the chosen set, or null for all apps.
class AppSetChoice {
  const AppSetChoice(this.id);
  final String? id;
}

/// One line about what a set does.
String describeAppSet(AppRoutingConfig config) {
  final n = config.packages.length;
  if (n == 0) return 'All apps';
  return '${config.mode == AppRoutingMode.whitelist ? 'Only' : 'All but'} $n app${n == 1 ? '' : 's'}';
}

/// Picks the app set a route or a server uses, and manages the sets: new,
/// edit, rename, share, export, import, delete.
class AppSetPickerScreen extends StatefulWidget {
  const AppSetPickerScreen({super.key, this.selected});

  final String? selected;

  @override
  State<AppSetPickerScreen> createState() => _AppSetPickerScreenState();
}

class _AppSetPickerScreenState extends State<AppSetPickerScreen> {
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

  Future<AppRoutingConfig?> _editApps(AppRoutingConfig initial) => Navigator.push<AppRoutingConfig>(
        context,
        MaterialPageRoute(builder: (_) => AppPickerScreen(initial: initial)),
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
          decoration: const InputDecoration(hintText: 'Browsers, Everything but banks…'),
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
    final config = await _editApps(const AppRoutingConfig.empty());
    if (config == null) return;
    final set = AppSet(id: AppSetRepository.newId(), name: name, config: config);
    await _repo.save(set);
    _pick(set.id);
  }

  Future<void> _import() async {
    final text = await importText(context);
    if (text == null) return;
    try {
      final set = SetArchive.decode(text, id: AppSetRepository.newId());
      if (set is! AppSet) throw const FormatException('This is a rule set, not an app set');
      await _repo.save(set);
      await _load();
      if (mounted) showToast(context, 'Imported "${set.name}".');
    } on FormatException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  Future<void> _action(AppSet set, String action) async {
    switch (action) {
      case 'apps':
        final config = await _editApps(set.config);
        if (config != null) await _repo.save(set.copyWith(config: config));
      case 'rename':
        final name = await _askName('Rename app set', initial: set.name);
        if (name != null) await _repo.save(set.copyWith(name: name));
      case 'share':
        await showShareDialog(context, 'appset/${set.id}', '"${set.name}"');
      case 'export':
        await exportText(context, fileName: SetArchive.appSetFile(set), text: SetArchive.encodeAppSet(set));
      case 'delete':
        await _repo.delete(set.id);
    }
    await _load();
  }

  Widget _tile({
    required String? id,
    required String title,
    String? subtitle,
    Widget? label,
    Widget? trailing,
  }) {
    final selected = id == widget.selected;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(title),
      subtitle: subtitle == null && label == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (subtitle != null) Text(subtitle),
                ?label,
              ],
            ),
      trailing: trailing,
      onTap: () => _pick(id),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ReceivedItems.instance,
      builder: (context, _) {
        final received = [
          for (final r in ReceivedItems.instance.appSets)
            if (!_own.any((s) => s.id == r.value.id)) r,
        ];
        return Scaffold(
          appBar: AppBar(
            title: const Text('Apps'),
            actions: [
              IconButton(
                icon: const Icon(Icons.file_open_outlined),
                tooltip: 'Import an app set',
                onPressed: _import,
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _new,
            icon: const Icon(Icons.add),
            label: const Text('New set'),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              _tile(id: null, title: 'All apps', subtitle: 'No set: everything goes through the tunnel'),
              const Divider(),
              for (final s in _own)
                _tile(
                  id: s.id,
                  title: s.name,
                  subtitle: describeAppSet(s.config),
                  label: ShareStatusLabel('appset/${s.id}'),
                  trailing: ActionSheetButton(
                    title: s.name,
                    actions: () => [
                      SheetAction('Edit apps', () => _action(s, 'apps'), icon: Icons.apps),
                      SheetAction('Rename', () => _action(s, 'rename'), icon: Icons.edit_outlined),
                      SheetAction('Share with my devices', () => _action(s, 'share'),
                          icon: Icons.devices),
                      SheetAction('Export', () => _action(s, 'export'), icon: Icons.ios_share),
                      SheetAction('Delete', () => _action(s, 'delete'),
                          icon: Icons.delete_outline, destructive: true),
                    ],
                  ),
                ),
              if (received.isNotEmpty) ...[
                const SectionHeader('On this network'),
                for (final r in received)
                  _tile(
                    id: r.value.id,
                    title: r.value.name,
                    subtitle: describeAppSet(r.value.config),
                    label: ShareStatusLabel.received('appset/${r.value.id}'),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
