import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../ssh/server_provisioner.dart';
import '../storage/admin_credentials.dart';
import '../storage/server_repository.dart';
import 'theme/app_theme.dart';
import '../sync/lan_sync.dart';

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
  bool _remember = false;
  bool _canRemember = false;
  bool _provisioning = false;
  String? _errorMessage;

  final _repo = ServerRepository();

  @override
  void initState() {
    super.initState();
    const UnlockWithDevice().available().then((v) {
      if (mounted) setState(() => _canRemember = v);
    });
  }

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
      await ProvisionServer(_repo)(server, adminIdentity, createdBy: LanSync.instance.name);
      // Kept only when asked to, and only once the device lock has been
      // shown to work.
      if (_remember &&
          await const UnlockWithDevice()('Save the admin password for ${server.nickname}')) {
        await const AdminCredentials().save(adminIdentity);
      }

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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Add server')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Enter your server credentials. Vzhukh will create a dedicated SSH user and generate a key. The password is not kept unless you ask below.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.lg),
              _field(
                controller: _nicknameCtrl,
                label: 'Nickname',
                hint: 'My VPS',
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: AppSpacing.md),
              _field(
                controller: _hostCtrl,
                label: 'Host',
                hint: '1.2.3.4 or example.com',
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: AppSpacing.md),
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
              const SizedBox(height: AppSpacing.md),
              _field(
                controller: _userCtrl,
                label: 'Admin username',
                hint: 'root',
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: AppSpacing.md),
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
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _remember,
                onChanged: _canRemember ? (v) => setState(() => _remember = v ?? false) : null,
                title: const Text('Remember the admin password on this device'),
                subtitle: Text(_canRemember
                    ? 'Unlocked with your fingerprint, face or device PIN when needed. Never shared.'
                    : 'Needs a screen lock on this device.'),
              ),
              const SizedBox(height: AppSpacing.md),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Text(
                    _errorMessage!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              FilledButton(
                onPressed: _provisioning ? null : _provision,
                child: _provisioning
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
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
        suffixIcon: suffixIcon,
      ),
      validator: validator,
    );
  }
}
