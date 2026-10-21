import 'dart:io';

import 'package:flutter/material.dart';

import 'storage/migrate_to_sets.dart';
import 'sync/lan_sync.dart';
import 'sync/sync_signal.dart';

import 'ui/devices/device_list_screen.dart';
import 'ui/lan_sync_screen.dart';
import 'ui/macos/rules_screen.dart';
import 'ui/macos/traffic_screen.dart';
import 'ui/server_list_screen.dart';
import 'ui/theme/app_theme.dart';
import 'ui/tv/tv_mode.dart';
import 'ui/tv/tv_shell.dart';
import 'vpn/vpn_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final isTv = await const DetectTvMode()();
  if (isTv) {
    // Flutter starts Android in touch highlight mode, which suppresses focus
    // rings until the first key press. On a TV there is nothing but the D-pad,
    // so focus must be visible from the very first frame.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  }

  // App lists move into app sets before anything reads them.
  await const MigrateToSets()();

  runApp(VzhukhApp(isTv: isTv));
  LanSync.instance.init(keepReceived: isTv);
}

class VzhukhApp extends StatelessWidget {
  const VzhukhApp({super.key, required this.isTv});

  final bool isTv;

  @override
  Widget build(BuildContext context) {
    return TvMode(
      isTv: isTv,
      child: MaterialApp(
        title: 'Vzhukh',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(tv: isTv),
        home: IncomingPairingListener(child: _HomeScreen(isTv: isTv)),
      ),
    );
  }
}

const _destinations = [
  (icon: Icons.dns_outlined, label: 'Servers'),
  (icon: Icons.tv_outlined, label: 'Devices'),
];

/// macOS adds the helper's two screens: what decides where traffic goes,
/// and what traffic actually did.
const _macDestinations = [
  ..._destinations,
  (icon: Icons.rule_outlined, label: 'Rules'),
  (icon: Icons.swap_vert, label: 'Traffic'),
];

class _HomeScreen extends StatefulWidget {
  const _HomeScreen({required this.isTv});

  final bool isTv;

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  final _vpn = VpnController();
  final _rulesKey = GlobalKey<RulesScreenState>();
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    SyncSignal.instance.remote.addListener(_vpn.applyRules);
  }

  @override
  void dispose() {
    SyncSignal.instance.remote.removeListener(_vpn.applyRules);
    _vpn.dispose();
    super.dispose();
  }

  void _select(int index) => setState(() => _tab = index);

  @override
  Widget build(BuildContext context) {
    if (widget.isTv) return TvShell(vpn: _vpn);

    return _buildHandheld([
      ServerListScreen(vpn: _vpn),
      const DeviceListScreen(),
      if (Platform.isMacOS) ...[
        RulesScreen(key: _rulesKey, vpn: _vpn),
        TrafficScreen(
          vpn: _vpn,
          visible: _tab == 3,
          onMakeRule: (draft) {
            _select(2);
            _rulesKey.currentState?.edit(draft: draft);
          },
        ),
      ],
    ]);
  }

  /// [IndexedStack] keeps every child mounted, so the hidden tab's widgets stay
  /// in the focus tree and a D-pad press can land on something that is not on
  /// screen. Only the visible tab may take focus.
  Widget _screenStack(List<Widget> screens) {
    return IndexedStack(
      index: _tab,
      children: [
        for (var i = 0; i < screens.length; i++)
          ExcludeFocus(excluding: i != _tab, child: screens[i]),
      ],
    );
  }

  Widget _buildHandheld(List<Widget> screens) {
    return Scaffold(
      body: _screenStack(screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _select,
        destinations: [
          for (final d in Platform.isMacOS ? _macDestinations : _destinations)
            NavigationDestination(
              icon: d.label == 'Traffic' ? _RecordingBadge(vpn: _vpn, child: Icon(d.icon)) : Icon(d.icon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

/// A red dot on the Traffic tab while the helper records, so a recording
/// left running is seen from any screen, also after the app restarts.
class _RecordingBadge extends StatelessWidget {
  const _RecordingBadge({required this.vpn, required this.child});

  final VpnController vpn;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final status = vpn.macDaemon?.daemonStatus;
    if (status == null) return child;
    return ValueListenableBuilder(
      valueListenable: status,
      builder: (context, s, _) => Badge(
        isLabelVisible: s?.recording ?? false,
        backgroundColor: AppColors.of(context).danger,
        smallSize: 8,
        child: child,
      ),
    );
  }
}
