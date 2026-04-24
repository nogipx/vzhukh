import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../ssh/server_provisioner.dart';
import '../storage/server_repository.dart';

class AddServerScreen extends StatefulWidget {
  const AddServerScreen({super.key});

  @override
  State<AddServerScreen> createState() => _AddServerScreenState();
}

class _AddServerScreenState extends State<AddServerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nicknameCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController(text: 'root');
  final _passCtrl = TextEditingController();
  bool _obscurePass = true;
  bool _provisioning = false;
  String? _errorMessage;

  final _repo = ServerRepository();

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _provision() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _provisioning = true;
      _errorMessage = null;
    });

    final server = Server(
      id: '${_hostCtrl.text.trim()}_${DateTime.now().millisecondsSinceEpoch}',
      host: _hostCtrl.text.trim(),
      port: int.parse(_portCtrl.text.trim()),
      nickname: _nicknameCtrl.text.trim(),
    );

    final adminIdentity = SshIdentity(
      id: '${server.id}_admin',
      serverId: server.id,
      username: _userCtrl.text.trim(),
      authType: SshAuthType.password,
      isAdmin: true,
      password: _passCtrl.text,
    );

    try {
      await _repo.saveServer(server);
      // Admin password is used only once and never stored.
      await ProvisionServer(_repo)(server, adminIdentity);

      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _provisioning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add server')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Enter your server credentials. Vzhukh will create a dedicated SSH user and generate a key — your password will not be stored.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              _field(
                controller: _nicknameCtrl,
                label: 'Nickname',
                hint: 'My VPS',
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              _field(
                controller: _hostCtrl,
                label: 'Host',
                hint: '1.2.3.4 or example.com',
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              _field(
                controller: _portCtrl,
                label: 'Port',
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
                label: 'Admin username',
                hint: 'root',
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              _field(
                controller: _passCtrl,
                label: 'Admin password',
                obscureText: _obscurePass,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.content_paste),
                      tooltip: 'Paste',
                      onPressed: () async {
                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                        if (data?.text != null) _passCtrl.text = data!.text!;
                      },
                    ),
                    IconButton(
                      icon: Icon(_obscurePass
                          ? Icons.visibility
                          : Icons.visibility_off),
                      onPressed: () =>
                          setState(() => _obscurePass = !_obscurePass),
                    ),
                  ],
                ),
                validator: (v) =>
                    v == null || v.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 24),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
              FilledButton(
                onPressed: _provisioning ? null : _provision,
                child: _provisioning
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Set up server'),
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
