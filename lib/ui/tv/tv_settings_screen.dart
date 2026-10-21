import 'package:flutter/material.dart';

import '../../sync/lan_sync.dart';
import '../theme/app_theme.dart';
import 'tv_actions.dart';
import 'tv_app_sets.dart';

/// This TV's own settings: its name on the network, whether it syncs, and
/// the app sets it can route.
class TvSettingsScreen extends StatelessWidget {
  const TvSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = LanSync.instance;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => TvPage(
        title: 'Settings',
        child: ListView(
          children: [
            TvRow(
              autofocus: true,
              icon: Icons.badge_outlined,
              title: 'Device name',
              subtitle: sync.name,
              trailing: const Icon(Icons.edit_outlined),
              onPressed: () => _rename(context),
            ),
            const SizedBox(height: AppSpacing.sm),
            TvRow(
              icon: Icons.wifi_tethering,
              title: 'Sync over the local network',
              subtitle:
                  'Paired devices find this TV and share servers and routes with it',
              // The row takes focus and toggles; the switch only shows the state.
              trailing: ExcludeFocus(
                child: Switch(value: sync.enabled, onChanged: sync.setEnabled),
              ),
              onPressed: () => sync.setEnabled(!sync.enabled),
            ),
            const SizedBox(height: AppSpacing.sm),
            TvRow(
              icon: Icons.apps,
              title: 'App sets',
              subtitle: 'Lists of apps a server or route can be limited to',
              trailing: const Icon(Icons.chevron_right),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const TvAppSetScreen(picking: false),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: LanSync.instance.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null) await LanSync.instance.setName(name);
  }
}
