import 'package:flutter/material.dart';

import 'ui/route_list_screen.dart';
import 'ui/server_list_screen.dart';
import 'ui/theme/app_theme.dart';
import 'ui/tv/tv_mode.dart';
import 'ui/tv/tv_nav_rail.dart';
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

  runApp(VzhukhApp(isTv: isTv));
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
        home: _HomeScreen(isTv: isTv),
      ),
    );
  }
}

const _destinations = [
  TvNavDestination(icon: Icons.dns_outlined, label: 'Servers'),
  TvNavDestination(icon: Icons.route_outlined, label: 'Routes'),
];

class _HomeScreen extends StatefulWidget {
  const _HomeScreen({required this.isTv});

  final bool isTv;

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  final _vpn = VpnController();
  int _tab = 0;

  @override
  void dispose() {
    _vpn.dispose();
    super.dispose();
  }

  void _select(int index) => setState(() => _tab = index);

  @override
  Widget build(BuildContext context) {
    if (widget.isTv) return TvShell(vpn: _vpn);

    return _buildHandheld([
      ServerListScreen(vpn: _vpn),
      RouteListScreen(vpn: _vpn),
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
          for (final d in _destinations)
            NavigationDestination(icon: Icon(d.icon), label: d.label),
        ],
      ),
    );
  }
}
