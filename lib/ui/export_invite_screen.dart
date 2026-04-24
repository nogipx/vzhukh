import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../ssh/invite_codec.dart';
import 'send_to_device_screen.dart';

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

  Future<void> _sendToDevice(String encoded) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SendToDeviceScreen.encoded(
          type: 'invite',
          encoded: encoded,
        ),
      ),
    );
  }

  void _generate() {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _error = null);

    try {
      final payload = InvitePayload(
        host: widget.server.host,
        port: widget.server.port,
        nickname: widget.server.nickname,
        username: widget.connection.username,
        privateKeyPem: widget.connection.privateKeyPem!,
      );
      final encoded = _codec.encode(payload, _passwordCtrl.text);
      setState(() => _encoded = encoded);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Export: ${widget.connection.label}')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.connection.canConnect)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.orange),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'This private key is not stored on this device. '
                        'If you close this screen without exporting, '
                        'you will need to revoke and recreate this connection.',
                        style: TextStyle(color: Colors.orange, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            const Text(
              'Set a password to encrypt the invite. Share the QR code and the password separately (e.g. QR via messenger, password in person).',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            Form(
              key: _formKey,
              child: TextFormField(
                controller: _passwordCtrl,
                obscureText: _obscurePass,
                decoration: InputDecoration(
                  labelText: 'Invite password',
                  border: const OutlineInputBorder(),
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
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _generate,
              child: const Text('Generate QR'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            if (_encoded != null) ...[
              const SizedBox(height: 32),
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(
                    data: _encoded!,
                    version: QrVersions.auto,
                    size: 280,
                    errorCorrectionLevel: QrErrorCorrectLevel.L,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _encoded!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy invite text'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _sendToDevice(_encoded!),
                icon: const Icon(Icons.send),
                label: const Text('Send to device'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
