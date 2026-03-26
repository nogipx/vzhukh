import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/app_routing_config.dart';
import '../models/server_config.dart';
import '../vpn/vpn_controller.dart';
import 'app_picker_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();

  bool _useKey = false;
  bool _obscurePass = true;
  AppRoutingConfig _routing = const AppRoutingConfig.empty();

  final _storage = const FlutterSecureStorage();
  final _vpn = VpnController();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final raw = await _storage.read(key: 'server_config');
    if (raw != null) {
      try {
        final cfg = ServerConfig.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
        _hostCtrl.text = cfg.host;
        _portCtrl.text = cfg.port.toString();
        _userCtrl.text = cfg.username;
        if (cfg.privateKey != null) {
          _keyCtrl.text = cfg.privateKey!;
          setState(() => _useKey = true);
        } else {
          _passCtrl.text = cfg.password ?? '';
        }
      } catch (_) {}
    }

    final rawRouting = await _storage.read(key: 'app_routing');
    if (rawRouting != null) {
      try {
        setState(() {
          _routing = AppRoutingConfig.fromJson(
            Map<String, dynamic>.from(jsonDecode(rawRouting) as Map),
          );
        });
      } catch (_) {}
    }
  }

  Future<void> _saveConfig(ServerConfig cfg) async {
    await _storage.write(key: 'server_config', value: jsonEncode(cfg.toJson()));
  }

  Future<void> _saveRouting(AppRoutingConfig routing) async {
    await _storage.write(key: 'app_routing', value: jsonEncode(routing.toJson()));
  }

  Future<void> _openAppPicker() async {
    final result = await Navigator.push<AppRoutingConfig>(
      context,
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(initial: _routing),
      ),
    );
    if (result != null) {
      setState(() => _routing = result);
      await _saveRouting(result);
    }
  }

  Future<void> _toggle() async {
    if (_vpn.status.value == VpnStatus.connected ||
        _vpn.status.value == VpnStatus.reconnecting) {
      await _vpn.disconnect();
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    final cfg = ServerConfig(
      host: _hostCtrl.text.trim(),
      port: int.parse(_portCtrl.text.trim()),
      username: _userCtrl.text.trim(),
      password: _useKey ? null : _passCtrl.text,
      privateKey: _useKey ? _keyCtrl.text : null,
    );
    await _saveConfig(cfg);
    await _vpn.connect(cfg, routing: _routing);
  }

  @override
  void dispose() {
    _vpn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vzhukh'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusCard(vpn: _vpn),
              const SizedBox(height: 24),
              _field(
                controller: _hostCtrl,
                label: 'SSH Host',
                hint: 'example.com or 1.2.3.4',
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              _field(
                controller: _portCtrl,
                label: 'SSH Port',
                hint: '22',
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  if (n == null || n <= 0 || n > 65535) return 'Invalid port';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              _field(
                controller: _userCtrl,
                label: 'Username',
                hint: 'root',
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Auth method:'),
                  const SizedBox(width: 16),
                  ChoiceChip(
                    label: const Text('Password'),
                    selected: !_useKey,
                    onSelected: (_) => setState(() => _useKey = false),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Private Key'),
                    selected: _useKey,
                    onSelected: (_) => setState(() => _useKey = true),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (!_useKey)
                _field(
                  controller: _passCtrl,
                  label: 'Password',
                  obscureText: _obscurePass,
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePass
                        ? Icons.visibility
                        : Icons.visibility_off),
                    onPressed: () =>
                        setState(() => _obscurePass = !_obscurePass),
                  ),
                  validator: (v) =>
                      !_useKey && (v == null || v.isEmpty) ? 'Required' : null,
                )
              else
                TextFormField(
                  controller: _keyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Private Key (PEM)',
                    hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 6,
                  validator: (v) =>
                      _useKey && (v == null || v.trim().isEmpty)
                          ? 'Required'
                          : null,
                ),
              const SizedBox(height: 16),
              if (Platform.isAndroid) _AppRoutingTile(
                routing: _routing,
                onTap: _openAppPicker,
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder(
                valueListenable: _vpn.status,
                builder: (context, status, _) {
                  final isConnecting = status == VpnStatus.connecting ||
                      status == VpnStatus.reconnecting;
                  final isConnected = status == VpnStatus.connected;
                  return FilledButton.icon(
                    onPressed: isConnecting ? null : _toggle,
                    icon: isConnecting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(isConnected ? Icons.stop : Icons.play_arrow),
                    label: Text(isConnected
                        ? 'Disconnect'
                        : status == VpnStatus.reconnecting
                            ? 'Reconnecting…'
                            : isConnecting
                                ? 'Connecting…'
                                : 'Connect'),
                    style: FilledButton.styleFrom(
                      backgroundColor: isConnected ? Colors.red : null,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscureText = false,
    TextInputType? keyboardType,
    Widget? suffixIcon,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        suffixIcon: suffixIcon,
      ),
      validator: validator,
    );
  }
}

class _AppRoutingTile extends StatelessWidget {
  final AppRoutingConfig routing;
  final VoidCallback onTap;

  const _AppRoutingTile({required this.routing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final count = routing.packages.length;
    final subtitle = count == 0
        ? 'All apps through tunnel'
        : '${routing.mode == AppRoutingMode.whitelist ? 'Only' : 'Except'} $count app${count == 1 ? '' : 's'}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.apps),
      title: const Text('App routing'),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _StatusCard extends StatelessWidget {
  final VpnController vpn;

  const _StatusCard({required this.vpn});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: vpn.status,
      builder: (context, status, _) {
        final (icon, label, color) = switch (status) {
          VpnStatus.disconnected => (Icons.wifi_off, 'Disconnected', Colors.grey),
          VpnStatus.connecting => (Icons.hourglass_top, 'Connecting…', Colors.orange),
          VpnStatus.connected => (Icons.verified_user, 'Connected', Colors.green),
          VpnStatus.reconnecting => (Icons.sync, 'Reconnecting…', Colors.orange),
          VpnStatus.error => (Icons.error_outline, 'Error', Colors.red),
        };

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Icon(icon, size: 48, color: color),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: color),
                ),
                if (status == VpnStatus.error)
                  ValueListenableBuilder(
                    valueListenable: vpn.errorMessage,
                    builder: (_, msg, __) => msg != null
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              msg,
                              style: const TextStyle(
                                  color: Colors.red, fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
