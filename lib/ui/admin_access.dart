import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../storage/admin_credentials.dart';
import 'theme/app_theme.dart';

/// Admin access to [server]: the saved password once the device owner has
/// unlocked it, or one typed in now (and saved, if they tick the box).
/// Null when they cancel.
Future<SshIdentity?> obtainAdminIdentity(BuildContext context, Server server) async {
  const store = AdminCredentials();
  if (await store.has(server.id)) {
    final unlocked =
        await const UnlockWithDevice()('Unlock the admin password for ${server.nickname}');
    if (!unlocked) return null;
    final saved = await store.read(server.id);
    if (saved != null) return saved;
    // Saved once, gone from the keychain since: ask again.
    await store.forget(server.id);
  }
  if (!context.mounted) return null;
  final canSave = await const UnlockWithDevice().available();
  if (!context.mounted) return null;
  final result = await showDialog<({SshIdentity admin, bool remember})>(
    context: context,
    builder: (_) => _AdminDialog(server: server, canSave: canSave),
  );
  if (result == null) return null;
  if (result.remember) {
    // Unlocking once now proves the lock works before anything relies on it.
    final ok = await const UnlockWithDevice()('Save the admin password for ${server.nickname}');
    if (ok) await store.save(result.admin);
  }
  return result.admin;
}

class _AdminDialog extends StatefulWidget {
  const _AdminDialog({required this.server, required this.canSave});

  final Server server;
  final bool canSave;

  @override
  State<_AdminDialog> createState() => _AdminDialogState();
}

class _AdminDialogState extends State<_AdminDialog> {
  final _user = TextEditingController(text: 'root');
  final _pass = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _obscure = true;
  bool _remember = false;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, (
      admin: SshIdentity(
        id: 'admin_temp',
        serverId: widget.server.id,
        username: _user.text.trim(),
        authType: SshAuthType.password,
        isAdmin: true,
        password: _pass.text,
      ),
      remember: _remember,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Admin access to ${widget.server.nickname}'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Admin username'),
              validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _pass,
              obscureText: _obscure,
              autofocus: true,
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Admin password',
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.content_paste),
                      tooltip: 'Paste',
                      onPressed: () async {
                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                        if (data?.text != null) _pass.text = data!.text!;
                      },
                    ),
                    IconButton(
                      icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ],
                ),
              ),
              validator: (v) => v == null || v.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _remember,
              onChanged: widget.canSave ? (v) => setState(() => _remember = v ?? false) : null,
              title: const Text('Remember on this device'),
              subtitle: Text(widget.canSave
                  ? 'Unlocked with your fingerprint, face or device PIN. Never shared.'
                  : 'Needs a screen lock on this device.'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}
