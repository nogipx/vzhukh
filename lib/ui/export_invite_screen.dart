import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../ssh/invite_codec.dart';
import 'common/widgets.dart';
import 'theme/app_theme.dart';

class ExportInviteScreen extends StatefulWidget {
  final Server server;
  final Connection connection;

  const ExportInviteScreen({
    super.key,
    required this.server,
    required this.connection,
  });

  @override
  State<ExportInviteScreen> createState() => _ExportInviteScreenState();
}

class _ExportInviteScreenState extends State<ExportInviteScreen> {
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePass = true;
  String? _encoded;
  String? _error;

  final _codec = const InviteCodec();

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  bool _generating = false;

  Future<void> _generate() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _error = null;
      _generating = true;
    });
    try {
      final payload = InvitePayload(
        host: widget.server.host,
        port: widget.server.port,
        nickname: widget.server.nickname,
        username: widget.connection.username,
        privateKeyPem: widget.connection.privateKeyPem!,
      );
      final encoded = await _codec.encodeAsync(payload, _passwordCtrl.text);
      if (mounted) setState(() => _encoded = encoded);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = AppColors.of(context).warning;
    return Scaffold(
      appBar: AppBar(title: Text('Export: ${widget.connection.label}')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.connection.canConnect)
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                decoration: BoxDecoration(
                  color: warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: warning),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded, color: warning),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        'This private key is not stored on this device. '
                        'If you close this screen without exporting, '
                        'you will need to revoke and recreate this connection.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: warning),
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              'Set a password to encrypt the invite. Share the QR code and the password separately (e.g. QR via messenger, password in person).',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            Form(
              key: _formKey,
              child: TextFormField(
                controller: _passwordCtrl,
                obscureText: _obscurePass,
                decoration: InputDecoration(
                  labelText: 'Invite password',
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscurePass ? Icons.visibility : Icons.visibility_off),
                    onPressed: () =>
                        setState(() => _obscurePass = !_obscurePass),
                  ),
                ),
                validator: (v) =>
                    v == null || v.isEmpty ? 'Required' : null,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: _generating ? null : _generate,
              child: _generating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Generate QR'),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (_encoded != null) ...[
              const SizedBox(height: AppSpacing.xl),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: const BoxDecoration(
                    // Black on white whatever the theme: scanners expect it.
                    color: Color(0xFFFFFFFF),
                    borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
                  ),
                  child: QrImageView(
                    data: _encoded!,
                    version: QrVersions.auto,
                    size: 280,
                    errorCorrectionLevel: QrErrorCorrectLevel.L,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF000000),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF000000),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _encoded!));
                  showToast(context, 'Copied to clipboard');
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy invite text'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
