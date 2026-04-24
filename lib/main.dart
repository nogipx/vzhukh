import 'package:flutter/material.dart';
import 'ui/route_list_screen.dart';
import 'ui/server_list_screen.dart';
import 'vpn/vpn_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VzhukhApp());
}

class VzhukhApp extends StatelessWidget {
  const VzhukhApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vzhukh',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00BCD4),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const _HomeScreen(),
    );
  }
}

class _HomeScreen extends StatefulWidget {
  const _HomeScreen();

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          ServerListScreen(vpn: _vpn),
          RouteListScreen(vpn: _vpn, routing: null),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dns_outlined), label: 'Servers'),
          NavigationDestination(icon: Icon(Icons.route_outlined), label: 'Routes'),
        ],
      ),
    );
  }
}
