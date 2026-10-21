import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/app_info.dart';
import '../models/app_routing_config.dart';
import '../vpn/list_android_apps.dart';
import 'theme/app_theme.dart';

class AppPickerScreen extends StatefulWidget {
  final AppRoutingConfig initial;

  const AppPickerScreen({super.key, required this.initial});

  @override
  State<AppPickerScreen> createState() => _AppPickerScreenState();
}

class _AppPickerScreenState extends State<AppPickerScreen> {
  List<AppInfo> _apps = [];
  bool _loading = true;
  late AppRoutingMode _mode;
  late Set<String> _selected;
  String _search = '';
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _mode = widget.initial.mode;
    _selected = widget.initial.packages.toSet();
    _loadApps();
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {
    final apps = await const ListAndroidApps()();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loading = false;
    });
  }

  List<AppInfo> get _filtered {
    if (_search.isEmpty) return _apps;
    final q = _search.toLowerCase();
    return _apps
        .where((a) =>
            a.label.toLowerCase().contains(q) ||
            a.packageName.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Routing'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              AppRoutingConfig(mode: _mode, packages: _selected.toList()),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
      body: Column(
        children: [
          _ModeSelector(mode: _mode, onChanged: (m) => setState(() => _mode = m)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            child: Focus(
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.arrowDown) {
                  _searchFocus.unfocus();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                focusNode: _searchFocus,
                decoration: const InputDecoration(
                  hintText: 'Search apps…',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
          ),
          if (_selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                children: [
                  Text(
                    '${_selected.length} selected',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _selected.clear()),
                    child: const Text('Clear all'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _filtered.length,
                    itemBuilder: (_, i) {
                      final app = _filtered[i];
                      final checked = _selected.contains(app.packageName);
                      return CheckboxListTile(
                        autofocus: i == 0,
                        value: checked,
                        onChanged: (_) => setState(() {
                          if (checked) {
                            _selected.remove(app.packageName);
                          } else {
                            _selected.add(app.packageName);
                          }
                        }),
                        secondary: app.icon != null
                            ? Image.memory(app.icon!, width: 40, height: 40)
                            : const Icon(Icons.android, size: 40),
                        title: Text(app.label),
                        subtitle: Text(
                          app.packageName,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ModeSelector extends StatelessWidget {
  final AppRoutingMode mode;
  final void Function(AppRoutingMode) onChanged;

  const _ModeSelector({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Routing mode', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          SegmentedButton<AppRoutingMode>(
            segments: const [
              ButtonSegment(
                value: AppRoutingMode.whitelist,
                label: Text('Whitelist'),
                icon: Icon(Icons.check_circle_outline),
              ),
              ButtonSegment(
                value: AppRoutingMode.blacklist,
                label: Text('Blacklist'),
                icon: Icon(Icons.block),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            mode == AppRoutingMode.whitelist
                ? 'Only selected apps go through the tunnel'
                : 'Selected apps bypass the tunnel',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
