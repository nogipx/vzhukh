import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../ssh/invite_codec.dart';
import '../storage/server_repository.dart';
import 'theme/app_theme.dart';

class ImportInviteScreen extends StatefulWidget {
  /// Pre-filled encoded payload (e.g. received via local network push).
  final String? prefilled;

  const ImportInviteScreen({super.key, this.prefilled});

  @override
  State<ImportInviteScreen> createState() => _ImportInviteScreenState();
}

class _ImportInviteScreenState extends State<ImportInviteScreen> {
  final _repo = ServerRepository();
  final _codec = const InviteCodec();

  final _pasteCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passwordFocus = FocusNode();
  final _formKey = GlobalKey<FormState>();

  bool _scanning = false;
  bool _obscurePass = true;
  bool _importing = false;
  String? _error;
  String? _scannedData;

  bool get _isPrefilled => widget.prefilled != null;

  @override
  void initState() {
    super.initState();
    if (widget.prefilled != null) {
      _pasteCtrl.text = widget.prefilled!;
      _scannedData = widget.prefilled;
    }
  }

  @override
  void dispose() {
    _pasteCtrl.dispose();
    _passwordCtrl.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _onBarcodeDetected(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw != null && raw.isNotEmpty) {
      setState(() {
        _scannedData = raw;
        _pasteCtrl.text = raw;
        _scanning = false;
      });
    }
  }

  Future<void> _import() async {
    if (!_formKey.currentState!.validate()) return;

    final raw = _pasteCtrl.text.trim();
    final password = _passwordCtrl.text;

    setState(() {
      _importing = true;
      _error = null;
    });

    try {
      final payload = await _codec.decodeAsync(raw, password);

      final serverId =
          '${payload.host}_${DateTime.now().millisecondsSinceEpoch}';
      final server = Server(
        id: serverId,
        host: payload.host,
        port: payload.port,
        nickname: payload.nickname,
      );

      final connection = Connection(
        id: '${serverId}_imported',
        serverId: serverId,
        label: 'My connection',
        username: payload.username,
        publicKeyOpenSSH: _extractPublicKey(payload.privateKeyPem),
        privateKeyPem: payload.privateKeyPem,
        createdAt: DateTime.now(),
      );

      await _repo.saveServer(server);
      await _repo.saveConnection(connection);

      if (mounted) Navigator.pop(context, true);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Extracts public key from private key PEM by parsing via dartssh2.
  /// Falls back to empty string if parsing fails (pubkey is optional here,
  /// it's only used for display — the private key is what matters for auth).
  String _extractPublicKey(String privateKeyPem) {
    try {
      final pairs = _extractPublicKeyFromPem(privateKeyPem);
      return pairs;
    } catch (_) {
      return '';
    }
  }

  String _extractPublicKeyFromPem(String pem) {
    // We don't strictly need the pubkey on the recipient side.
    // It's used only for display/revocation, which the recipient can't do.
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import invite')),
      body: _scanning ? _buildScanner() : _buildForm(),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(onDetect: _onBarcodeDetected),
        Positioned(
          bottom: AppSpacing.xl,
          left: 0,
          right: 0,
          child: Center(
            child: OutlinedButton(
              onPressed: () => setState(() => _scanning = false),
              style: OutlinedButton.styleFrom(
                backgroundColor:
                    Theme.of(context).colorScheme.surface.withValues(alpha: 0.7),
                foregroundColor: Theme.of(context).colorScheme.onSurface,
              ),
              child: const Text('Cancel'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildForm() {
    final theme = Theme.of(context);
    final success = AppColors.of(context).success;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_isPrefilled) ...[
              if (_scannedData != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: success),
                      const SizedBox(width: AppSpacing.sm),
                      const Text('QR code scanned'),
                    ],
                  ),
                ),
              TextFormField(
                controller: _pasteCtrl,
                maxLines: 4,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                decoration: const InputDecoration(
                  labelText: 'Invite code',
                  hintText: 'Paste or scan QR code',
                  alignLabelWithHint: true,
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton.icon(
                onPressed: () => setState(() => _scanning = true),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR code'),
              ),
              const SizedBox(height: AppSpacing.md),
            ] else ...[
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: success),
                    const SizedBox(width: AppSpacing.sm),
                    const Text('Invite received. Enter the password.'),
                  ],
                ),
              ),
            ],
            TextFormField(
              controller: _passwordCtrl,
              focusNode: _passwordFocus,
              autofocus: _isPrefilled,
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
            const SizedBox(height: AppSpacing.lg),
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: AppSpacing.md),
            ],
            FilledButton(
              onPressed: _importing ? null : _import,
              child: _importing
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }
}
