import 'package:flutter/material.dart';

import '../../sync/lan_sync.dart';
import '../action_sheet.dart';
import '../common/widgets.dart';
import '../lan_sync_screen.dart';
import '../theme/app_theme.dart';
import 'tv_actions.dart';
import 'tv_button.dart';
import 'tv_confirm_dialog.dart';

/// Paired devices and devices on the network to pair with, on a TV.
/// The phone usually starts pairing and this TV shows the passkey; pairing
/// from here works too, with the code typed on the remote.
class TvDevicesScreen extends StatelessWidget {
  const TvDevicesScreen({super.key});

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _unpair(BuildContext context, PairedDevice device) => showTvActions(
        context,
        title: device.name,
        actions: [
          SheetAction('Unpair', () async {
            final ok = await showTvConfirmDialog(
              context,
              title: 'Unpair ${device.name}?',
              message: 'What it shared with this TV goes, and it gets nothing more from here.',
              confirmLabel: 'Unpair',
            );
            if (ok) await LanSync.instance.forget(device.key);
          }, icon: Icons.link_off, destructive: true),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final sync = LanSync.instance;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final colors = AppColors.of(context);
        var first = true;
        bool autofocus() {
          final f = first;
          first = false;
          return f;
        }

        Widget gap(Widget child) =>
            Padding(padding: const EdgeInsets.only(bottom: AppSpacing.sm), child: child);
        const headerPadding = EdgeInsets.fromLTRB(
            AppFocus.ringWidth + AppFocus.gap, AppSpacing.md, 0, AppSpacing.xs);

        return TvPage(
          title: 'Devices',
          subtitle: 'This TV is "${sync.name}"',
          action: TvButton(
            label: 'Sync now',
            icon: Icons.sync,
            filled: false,
            compact: true,
            minWidth: 0,
            // The start for the remote when there is no device to focus.
            autofocus: sync.paired.isEmpty && sync.nearby.isEmpty,
            onPressed: sync.syncNow,
          ),
          child: ListView(
            children: [
              if (sync.error != null)
                gap(TvRow(
                  icon: Icons.error_outline,
                  iconColor: colors.danger,
                  title: sync.error!,
                  enabled: false,
                )),
              const SectionHeader('Paired', padding: headerPadding),
              if (sync.paired.isEmpty)
                gap(const TvRow(
                  icon: Icons.info_outline,
                  title: 'Nothing paired yet',
                  subtitle: 'Open Vzhukh on your phone, Devices, and pair with this TV',
                  enabled: false,
                )),
              for (final p in sync.paired)
                gap(() {
                  final online = sync.isOnline(p.key);
                  final error = sync.lastError(p.key);
                  final last = sync.lastSync(p.key);
                  return TvRow(
                    autofocus: autofocus(),
                    icon: Icons.devices,
                    iconColor: online ? colors.success : null,
                    title: p.name,
                    subtitle: !online
                        ? 'Not on this network'
                        : error ?? (last == null ? 'Online' : 'Synced at ${_time(last)}'),
                    onPressed: () => _unpair(context, p),
                  );
                }()),
              const SectionHeader('On this network', padding: headerPadding),
              if (!sync.running)
                gap(const TvRow(
                  icon: Icons.wifi_off,
                  title: 'Sync is off',
                  subtitle: 'Turn it on in Settings',
                  enabled: false,
                ))
              else if (sync.nearby.isEmpty)
                gap(const TvRow(
                  icon: Icons.search,
                  title: 'Looking for devices',
                  subtitle: 'Open Vzhukh on them, on the same network',
                  enabled: false,
                )),
              for (final d in sync.nearby)
                gap(TvRow(
                  autofocus: autofocus(),
                  icon: Icons.devices_other,
                  title: d.name,
                  subtitle: 'OK to pair',
                  trailing: const Icon(Icons.link),
                  onPressed: () => pairWithDevice(context, d),
                )),
            ],
          ),
        );
      },
    );
  }
}
