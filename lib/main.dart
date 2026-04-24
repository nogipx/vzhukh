import 'package:flutter/material.dart';
import 'ui/server_list_screen.dart';

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
      home: const ServerListScreen(),
    );
  }
}
